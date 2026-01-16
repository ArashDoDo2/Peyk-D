package main

import (
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	LISTEN_IP   = "0.0.0.0"
	LISTEN_PORT = 53
	BASE_DOMAIN = "p99.online.ir"

	ACK_IP = "3.4.0.0" // server-received ACK (A)
)

// Debug knobs
const (
	DEBUG_STATS_EVERY = 10 * time.Second
	GC_EVERY          = 20 * time.Second
	MESSAGE_TTL       = 24 * time.Hour
	PAYLOAD_PREVIEW   = 24 // chars
	ENABLE_STATS_LOG  = false
	ENABLE_VERBOSE_LOG = false
	ENABLE_POLL_LOG    = true
	ENABLE_RX_CHUNK_LOG = false
	ENABLE_ACK2_LOG     = false
	ENABLE_GC_LOG       = true
	ACK2_TTL           = 24 * time.Hour
	ENABLE_EVENT_LOG   = true
	ENABLE_COLOR_LOG   = true
	RESEND_BACKOFF_START = 6
	RESEND_BACKOFF_MAX  = 30 * time.Second
	LEGACY_RESEND_CAP   = 60
)

// DNS Types
const (
	QTYPE_A    = 1
	QTYPE_TXT  = 16
	QTYPE_AAAA = 28
)

// ───────────────────────── Memory Store ─────────────────────────

// ChunkEnvelope = idx-tot-sid-rid-payload
type ChunkEnvelope struct {
	Idx     int
	Tot     int
	MID     string
	SID     string
	RID     string
	Payload string
	AddedAt time.Time
}

type sendState struct {
	Count    int
	LastSent time.Time
}

// messageStore:
// map[receiverID]map[messageKey][]ChunkEnvelope
// messageKey = sid + ":" + tot
var (
	messageStore = make(map[string]map[string][]ChunkEnvelope)

	// deliveryAcks: map[senderID][]string
	// payload: "ACK2-<sid>-<tot>"
	deliveryAcks = make(map[string][]string)
	ack2Seen     = make(map[string]time.Time)
	msgFirstAt   = make(map[string]time.Time)
	sendFirstAt  = make(map[string]time.Time)
	sendCursor   = make(map[string]int)
	sendStates   = make(map[string]sendState)

	storeMu sync.Mutex
)

// ───────────────────────── Stats ─────────────────────────

var (
	statRxPackets uint64
	statTxPackets uint64

	statRxChunks     uint64
	statRxDupChunks  uint64
	statRxAck2       uint64
	statPollRequests uint64

	statTxA    uint64 // generic A sends (incl ACK)
	statTxAAAA uint64 // polling payload via AAAA
	statTxAPay uint64 // polling payload via A (fallback)
	statTxTXT  uint64 // legacy (should remain 0 now)

	statParseFail uint64
	statIgnored   uint64
)

func logIf(enabled bool, format string, args ...interface{}) {
	if enabled {
		log.Printf(format, args...)
	}
}

func logEvent(tag, color, format string, args ...interface{}) {
	if !ENABLE_EVENT_LOG {
		return
	}
	prefix := tag
	if ENABLE_COLOR_LOG && color != "" {
		prefix = color + tag + "\x1b[0m"
	}
	log.Printf(prefix+" "+format, args...)
}

// ───────────────────────── Main ─────────────────────────

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	addr := net.UDPAddr{Port: LISTEN_PORT, IP: net.ParseIP(LISTEN_IP)}
	conn, err := net.ListenUDP("udp", &addr)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()

	go garbageCollector()
	go statsLogger()

    log.Printf("PEYK-D server listening on %s:%d (udp)", LISTEN_IP, LISTEN_PORT)

	buf := make([]byte, 512)
	for {
		n, remoteAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		atomic.AddUint64(&statRxPackets, 1)

		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		go handlePacket(conn, remoteAddr, pkt)
	}
}

// ───────────────────────── DNS Parsing ─────────────────────────

type dnsQuestion struct {
	QName  string
	QType  uint16
	QClass uint16
}

func parseQuestion(msg []byte) (dnsQuestion, bool) {
	if len(msg) < 12+5 {
		return dnsQuestion{}, false
	}
	name, off, ok := parseQNameNoCompression(msg, 12)
	if !ok || off+4 > len(msg) {
		return dnsQuestion{}, false
	}
	qtype := binary.BigEndian.Uint16(msg[off : off+2])
	qclass := binary.BigEndian.Uint16(msg[off+2 : off+4])
	return dnsQuestion{QName: name, QType: qtype, QClass: qclass}, true
}

func parseQNameNoCompression(msg []byte, start int) (string, int, bool) {
	var labels []string
	i := start
	for {
		if i >= len(msg) {
			return "", 0, false
		}
		l := int(msg[i])
		if l == 0 {
			i++
			break
		}
		if l > 63 || i+1+l > len(msg) {
			return "", 0, false
		}
		labels = append(labels, string(msg[i+1:i+1+l]))
		i += 1 + l
	}
	return strings.Join(labels, "."), i, true
}

// ───────────────────────── Packet Router ─────────────────────────

func handlePacket(conn *net.UDPConn, addr *net.UDPAddr, data []byte) {
	start := time.Now()

	q, ok := parseQuestion(data)
	if !ok {
		atomic.AddUint64(&statParseFail, 1)
		return
	}

	domain := strings.ToLower(q.QName)
	if !strings.HasSuffix(domain, BASE_DOMAIN) {
		atomic.AddUint64(&statIgnored, 1)
		return
	}

	txID := data[:2]
	txIDHex := fmt.Sprintf("%02x%02x", txID[0], txID[1])

	logIf(ENABLE_VERBOSE_LOG, "RX pkt from=%s txid=%s qtype=%d qname=%s", addr.String(), txIDHex, q.QType, domain)

	// Polling (NOW: AAAA preferred, fallback to A)
	if strings.HasPrefix(domain, "v1.sync.") {
		// Allow AAAA (28) and A (1). Ignore TXT now.
		if q.QType != QTYPE_AAAA && q.QType != QTYPE_A {
			atomic.AddUint64(&statIgnored, 1)
			return
		}
		atomic.AddUint64(&statPollRequests, 1)
		handlePolling(conn, addr, txID, domain, q.QType, q.QClass)
    logIf(ENABLE_VERBOSE_LOG, "done poll from=%s txid=%s took=%s", addr.String(), txIDHex, time.Since(start))
		return
	}

	// Inbound chunk or ACK2 (A/AAAA)
	if q.QType != QTYPE_A && q.QType != QTYPE_AAAA {
		atomic.AddUint64(&statIgnored, 1)
		return
	}
	handleInboundOrAck2(conn, addr, txID, domain, q.QType, q.QClass)
	logIf(ENABLE_VERBOSE_LOG, "done A from=%s txid=%s took=%s", addr.String(), txIDHex, time.Since(start))
}

// ───────────────────────── Inbound + ACK2 ─────────────────────────

func handleInboundOrAck2(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain string, qtype, qclass uint16) {
	prefix := strings.TrimSuffix(domain, "."+BASE_DOMAIN)
	label := prefix
	if dot := strings.IndexByte(prefix, '.'); dot >= 0 {
		label = prefix[:dot]
	}

	// ACK2: ack2-sid-tot or ack2-sid-tot-mid
	if strings.HasPrefix(label, "ack2-") {
		parts := strings.Split(label, "-")
		if len(parts) < 3 || len(parts) > 4 {
			return
		}
		sid := strings.ToLower(parts[1])
		tot := atoiSafe(parts[2])
		mid := ""
		if len(parts) == 4 {
			mid = strings.ToLower(parts[3])
		}
		if tot <= 0 {
			return
		}

		ack := fmt.Sprintf("ACK2-%s-%d", sid, tot)
		if mid != "" {
			ack = fmt.Sprintf("ACK2-%s-%d-%s", sid, tot, mid)
		}

		storeMu.Lock()
		ackKey := fmt.Sprintf("%s:%d:%s", sid, tot, mid)
		lastSeen, seen := ack2Seen[ackKey]
		if !seen || time.Since(lastSeen) > ACK2_TTL {
			deliveryAcks[sid] = append(deliveryAcks[sid], ack)
			ack2Seen[ackKey] = time.Now()
		}
		queueLen := len(deliveryAcks[sid])

		// Drop stored chunks for this message (stop resends after ACK2).
		msgKey := ""
		if mid != "" {
			msgKey = fmt.Sprintf("%s:%s:%d", sid, mid, tot)
		} else {
			msgKey = fmt.Sprintf("%s:%d", sid, tot)
		}
		ridMatches := make([]string, 0, 2)
		for rid, msgs := range messageStore {
			if _, ok := msgs[msgKey]; ok {
				ridMatches = append(ridMatches, rid)
			}
		}
		if mid != "" || len(ridMatches) == 1 {
			for _, rid := range ridMatches {
				msgs := messageStore[rid]
				delete(msgs, msgKey)
				delete(sendCursor, fmt.Sprintf("%s|%s", rid, msgKey))
				delete(msgFirstAt, fmt.Sprintf("%s|%s", rid, msgKey))
				delete(sendStates, fmt.Sprintf("%s|%s", rid, msgKey))
				if start, okStart := sendFirstAt[fmt.Sprintf("%s|%s", rid, msgKey)]; okStart {
					delete(sendFirstAt, fmt.Sprintf("%s|%s", rid, msgKey))
					logEvent("[MSG-TX]", "\x1b[33m", "ack received sid=%s -> rid=%s parts=%d took=%s", sid, rid, tot, time.Since(start))
				}
				if len(msgs) == 0 {
					delete(messageStore, rid)
				}
			}
		} else {
			logIf(ENABLE_ACK2_LOG, "ACK2 cleanup skipped for sid=%s tot=%d (ambiguous rid, mid missing)", sid, tot)
		}
		storeMu.Unlock()

		atomic.AddUint64(&statRxAck2, 1)
		if mid != "" {
			logEvent("[ACK2-RX]", "\x1b[36m", "delivery confirmed sid=%s tot=%d mid=%s from=%s queue=%d", sid, tot, mid, addr.String(), queueLen)
		} else {
			logEvent("[ACK2-RX]", "\x1b[36m", "delivery confirmed sid=%s tot=%d from=%s queue=%d", sid, tot, addr.String(), queueLen)
		}
		if mid != "" {
			logIf(ENABLE_ACK2_LOG, "ACK2 stored sid=%s tot=%d mid=%s (queue=%d) from=%s", sid, tot, mid, queueLen, addr.String())
		} else {
			logIf(ENABLE_ACK2_LOG, "ACK2 stored sid=%s tot=%d (queue=%d) from=%s", sid, tot, queueLen, addr.String())
		}

		// Keep ACK response as A with fixed ACK_IP (unchanged)
		sendAResponse(conn, addr, txID, domain, ACK_IP, qtype, qclass)
		return
	}
	// Chunk: idx-tot-sid-rid-payload (legacy) or idx-tot-mid-sid-rid-payload
	labels := strings.Split(label, "-")
	if len(labels) < 5 {
		return
	}

	idx := atoiSafe(labels[0])
	tot := atoiSafe(labels[1])
	mid := ""
	sid := ""
	rid := ""
	payload := ""

	if len(labels) >= 6 && isBase32ID(labels[2]) && isBase32ID(labels[3]) && isBase32ID(labels[4]) {
		mid = strings.ToLower(labels[2])
		sid = strings.ToLower(labels[3])
		rid = strings.ToLower(labels[4])
		payload = strings.Join(labels[5:], "-")
	} else {
		sid = strings.ToLower(labels[2])
		rid = strings.ToLower(labels[3])
		payload = strings.Join(labels[4:], "-")
	}

	if idx <= 0 || tot <= 0 || idx > tot || payload == "" {
		return
	}

	env := ChunkEnvelope{
		Idx:     idx,
		Tot:     tot,
		MID:     mid,
		SID:     sid,
		RID:     rid,
		Payload: payload,
		AddedAt: time.Now(),
	}

	key := ""
	if mid != "" {
		key = fmt.Sprintf("%s:%s:%d", sid, mid, tot)
	} else {
		key = fmt.Sprintf("%s:%d", sid, tot)
	}

	var (
		dup     bool
		msgSize int
	)

	storeMu.Lock()
	if messageStore[rid] == nil {
		messageStore[rid] = make(map[string][]ChunkEnvelope)
	}

	keyFull := fmt.Sprintf("%s|%s", rid, key)
	if _, ok := msgFirstAt[keyFull]; !ok {
		msgFirstAt[keyFull] = time.Now()
	}

	for _, c := range messageStore[rid][key] {
		if c.Idx == env.Idx {
			dup = true
			break
		}
	}

	if !dup {
		messageStore[rid][key] = append(messageStore[rid][key], env)
		msgSize = len(messageStore[rid][key])
	}

	firstAt := msgFirstAt[keyFull]
	if msgSize == tot && !firstAt.IsZero() {
		delete(msgFirstAt, keyFull)
	}
	storeMu.Unlock()

	if dup {
		atomic.AddUint64(&statRxDupChunks, 1)
		logIf(ENABLE_RX_CHUNK_LOG, "DUP chunk sid=%s->%s %d/%d from=%s", sid, rid, idx, tot, addr.String())
	} else {
		atomic.AddUint64(&statRxChunks, 1)
		logIf(ENABLE_RX_CHUNK_LOG, "RX chunk sid=%s->%s %d/%d payloadLen=%d key=%s chunksInKey=%d preview=%q",
			sid, rid, idx, tot, len(payload), key, msgSize, preview(payload))
	}

	if msgSize == tot {
		if firstAt.IsZero() {
			firstAt = time.Now()
		}
		logEvent("[MSG-RX]", "\x1b[32m", "complete sid=%s -> rid=%s parts=%d took=%s", sid, rid, tot, time.Since(firstAt))
	}

	// ACK for inbound chunk remains A
	sendAResponse(conn, addr, txID, domain, ACK_IP, qtype, qclass)
}

// ───────────────────────── Polling ─────────────────────────

func handlePolling(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain string, qtype, qclass uint16) {
	parts := strings.Split(domain, ".")
	if len(parts) < 3 {
        logIf(ENABLE_VERBOSE_LOG, "poll malformed qname=%s from=%s -> NOP", domain, addr.String())
		sendPollingPayload(conn, addr, txID, domain, "NOP", qtype, qclass)
		return
	}
	rid := strings.ToLower(parts[2])

	// 1) ACK2s
	storeMu.Lock()
	if acks, ok := deliveryAcks[rid]; ok && len(acks) > 0 {
		ack := acks[0]
		remaining := len(acks) - 1
		if len(acks) == 1 {
			delete(deliveryAcks, rid)
		} else {
			deliveryAcks[rid] = acks[1:]
		}
		storeMu.Unlock()

		logIf(ENABLE_POLL_LOG, "poll rid=%s from=%s -> ACK2 (%s) remaining=%d viaQ=%d", rid, addr.String(), ack, remaining, qtype)
		logEvent("[ACK2-TX]", "\x1b[35m", "sent to rid=%s ack=%s remaining=%d viaQ=%d", rid, ack, remaining, qtype)
		sendPollingPayload(conn, addr, txID, domain, ack, qtype, qclass)
		return
	}

	// 2) Chunks
	msgs, ok := messageStore[rid]
	if !ok || len(msgs) == 0 {
		storeMu.Unlock()

		sendPollingPayload(conn, addr, txID, domain, "NOP", qtype, qclass)
		return
	}

	now := time.Now()
	for key, chunks := range msgs {
		keyFull := fmt.Sprintf("%s|%s", rid, key)
		state := sendStates[keyFull]
		if !state.LastSent.IsZero() {
			backoff := resendBackoff(state.Count)
			if backoff > 0 && now.Sub(state.LastSent) < backoff {
				continue
			}
		}

		if chunks[0].MID == "" && state.Count >= LEGACY_RESEND_CAP {
			logIf(ENABLE_POLL_LOG, "poll rid=%s from=%s -> DROP legacy key=%s after=%d sends", rid, addr.String(), key, state.Count)
			delete(msgs, key)
			delete(sendCursor, keyFull)
			delete(msgFirstAt, keyFull)
			delete(sendFirstAt, keyFull)
			delete(sendStates, keyFull)
			if len(msgs) == 0 {
				delete(messageStore, rid)
			}
			continue
		}

		nextIdx := sendCursor[keyFull]
		if nextIdx <= 0 {
			nextIdx = 1
		}

		var c ChunkEnvelope
		found := false
		for _, chunk := range chunks {
			if chunk.Idx == nextIdx {
				c = chunk
				found = true
				break
			}
		}
		if !found {
			nextIdx = 1
			for _, chunk := range chunks {
				if chunk.Idx == nextIdx {
					c = chunk
					found = true
					break
				}
			}
		}
		if !found {
			c = chunks[0]
		}
		sendCursor[keyFull] = c.Idx + 1
		if sendCursor[keyFull] > c.Tot {
			sendCursor[keyFull] = 1
		}

		full := ""
		if c.MID != "" {
			full = fmt.Sprintf("%d-%d-%s-%s-%s-%s", c.Idx, c.Tot, c.MID, c.SID, c.RID, c.Payload)
		} else {
			full = fmt.Sprintf("%d-%d-%s-%s-%s", c.Idx, c.Tot, c.SID, c.RID, c.Payload)
		}

		// NOTE: We no longer have TXT 255 limitation; keep a sane cap anyway to avoid huge DNS responses.
		// 480 bytes cap keeps us safe under typical 512-byte UDP DNS while still useful.
		if len(full) > 480 {
			full = full[:480]
		}

		leftInKey := len(chunks)
		if _, ok := sendFirstAt[keyFull]; !ok {
			sendFirstAt[keyFull] = now
		}
		state.Count++
		state.LastSent = now
		sendStates[keyFull] = state
		storeMu.Unlock()

		logIf(ENABLE_POLL_LOG, "poll rid=%s from=%s -> CHUNK key=%s sent=%d/%d sid=%s payloadLen=%d leftInKey=%d viaQ=%d preview=%q",
			rid, addr.String(), key, c.Idx, c.Tot, c.SID, len(c.Payload), leftInKey, qtype, preview(full))

		sendPollingPayload(conn, addr, txID, domain, full, qtype, qclass)
		return
	}

	// should not reach
	storeMu.Unlock()
	sendPollingPayload(conn, addr, txID, domain, "NOP", qtype, qclass)
}

// sendPollingPayload sends payload using AAAA if requested; otherwise A fallback.
// Payload is encoded into multiple AAAA or A RRs (raw bytes packed into IPs).
func sendPollingPayload(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain, payload string, qtype, qclass uint16) {
	if qtype == QTYPE_AAAA {
		sendAAAABytesResponse(conn, addr, txID, domain, []byte(payload), qclass)
		return
	}
	// fallback: A
	sendABytesResponse(conn, addr, txID, domain, []byte(payload), qclass)
}

func resendBackoff(count int) time.Duration {
	if count < RESEND_BACKOFF_START {
		return 0
	}
	step := count - RESEND_BACKOFF_START
	if step < 0 {
		return 0
	}
	delay := time.Duration(1<<step) * time.Second
	if delay > RESEND_BACKOFF_MAX {
		return RESEND_BACKOFF_MAX
	}
	return delay
}

// ───────────────────────── GC ─────────────────────────

func garbageCollector() {
	ticker := time.NewTicker(GC_EVERY)
	defer ticker.Stop()

	for range ticker.C {
		now := time.Now()

		var (
			beforeChunks int
			afterChunks  int
			expired      int
			keysRemoved  int
			ridsRemoved  int
			ack2Removed  int
		)

		storeMu.Lock()
		for rid, msgs := range messageStore {
			for key, chunks := range msgs {
				beforeChunks += len(chunks)
				filtered := chunks[:0]
				for _, c := range chunks {
					if now.Sub(c.AddedAt) < MESSAGE_TTL {
						filtered = append(filtered, c)
					} else {
						expired++
					}
				}
				if len(filtered) == 0 {
					delete(msgs, key)
					keysRemoved++
					delete(sendCursor, fmt.Sprintf("%s|%s", rid, key))
					delete(msgFirstAt, fmt.Sprintf("%s|%s", rid, key))
					delete(sendFirstAt, fmt.Sprintf("%s|%s", rid, key))
				} else {
					msgs[key] = filtered
					afterChunks += len(filtered)
				}
			}
			if len(msgs) == 0 {
				delete(messageStore, rid)
				ridsRemoved++
			}
		}
		for key, ts := range msgFirstAt {
			if now.Sub(ts) > MESSAGE_TTL {
				delete(msgFirstAt, key)
			}
		}
		for key, ts := range sendFirstAt {
			if now.Sub(ts) > MESSAGE_TTL {
				delete(sendFirstAt, key)
			}
		}
		for key := range sendCursor {
			if _, ok := sendFirstAt[key]; !ok {
				// cursor without active key (message expired or cleaned)
				delete(sendCursor, key)
			}
		}
		for key := range sendStates {
			if _, ok := sendFirstAt[key]; !ok {
				delete(sendStates, key)
			}
		}
		storeMu.Unlock()

		storeMu.Lock()
		for key, ts := range ack2Seen {
			if now.Sub(ts) > ACK2_TTL {
				delete(ack2Seen, key)
				ack2Removed++
			}
		}
		storeMu.Unlock()

		if expired > 0 || keysRemoved > 0 || ridsRemoved > 0 || ack2Removed > 0 {
			logIf(ENABLE_GC_LOG, "GC expired=%d chunks (before=%d after=%d) keysRemoved=%d ridsRemoved=%d ack2Removed=%d ttl=%s",
				expired, beforeChunks, afterChunks, keysRemoved, ridsRemoved, ack2Removed, MESSAGE_TTL)
		}
	}
}

// ───────────────────────── Stats Logger ─────────────────────────

func statsLogger() {
	if !ENABLE_STATS_LOG {
		return
	}
	ticker := time.NewTicker(DEBUG_STATS_EVERY)
	defer ticker.Stop()

	for range ticker.C {
		var (
			rx = atomic.LoadUint64(&statRxPackets)
			tx = atomic.LoadUint64(&statTxPackets)

			rxChunks    = atomic.LoadUint64(&statRxChunks)
			rxDupChunks = atomic.LoadUint64(&statRxDupChunks)
			rxAck2      = atomic.LoadUint64(&statRxAck2)
			polls       = atomic.LoadUint64(&statPollRequests)

			txA    = atomic.LoadUint64(&statTxA)
			txAAAA = atomic.LoadUint64(&statTxAAAA)
			txAPay = atomic.LoadUint64(&statTxAPay)
			txTXT  = atomic.LoadUint64(&statTxTXT)

			parseFail = atomic.LoadUint64(&statParseFail)
			ignored   = atomic.LoadUint64(&statIgnored)
		)

		storeMu.Lock()
		var (
			ridCount   = len(messageStore)
			keyCount   = 0
			chunkCount = 0
			ackUsers   = len(deliveryAcks)
			ackCount   = 0
		)
		for _, msgs := range messageStore {
			keyCount += len(msgs)
			for _, chunks := range msgs {
				chunkCount += len(chunks)
			}
		}
		for _, acks := range deliveryAcks {
			ackCount += len(acks)
		}
		storeMu.Unlock()

		log.Printf("📊 STATS rx=%d tx=%d polls=%d rxChunks=%d dupChunks=%d rxAck2=%d txA=%d txAAAA=%d txAPay=%d txTXT=%d parseFail=%d ignored=%d store[rids=%d keys=%d chunks=%d] acks[users=%d total=%d]",
			rx, tx, polls, rxChunks, rxDupChunks, rxAck2, txA, txAAAA, txAPay, txTXT, parseFail, ignored,
			ridCount, keyCount, chunkCount, ackUsers, ackCount)
	}
}

// ───────────────────────── DNS Builders ─────────────────────────

func buildBaseResponse(txID []byte, domain string, qtype, qclass uint16, ancount uint16) []byte {
	resp := make([]byte, 0, 512)

	resp = append(resp, txID[0], txID[1])
	resp = append(resp, 0x84, 0x00) // QR + AA
	resp = append(resp, 0x00, 0x01) // QDCOUNT=1
	resp = append(resp, byte(ancount>>8), byte(ancount))
	resp = append(resp, 0x00, 0x00, 0x00, 0x00) // NS/AR=0

	// QNAME
	for _, label := range strings.Split(domain, ".") {
		if label == "" {
			continue
		}
		resp = append(resp, byte(len(label)))
		resp = append(resp, []byte(label)...)
	}
	resp = append(resp, 0x00)

	// QTYPE/QCLASS
	tmp := make([]byte, 4)
	binary.BigEndian.PutUint16(tmp[0:2], qtype)
	binary.BigEndian.PutUint16(tmp[2:4], qclass)
	resp = append(resp, tmp...)

	return resp
}

// Original ACK response (single A RR)
func sendAResponse(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain, ipStr string, qtype, qclass uint16) {
	resp := buildBaseResponse(txID, domain, qtype, qclass, 1)
	resp = append(resp,
		0xc0, 0x0c, // NAME ptr
		0x00, 0x01, // TYPE A
		0x00, 0x01, // CLASS IN
		0x00, 0x00, 0x00, 0x1e, // TTL 30s
		0x00, 0x04, // RDLEN 4
	)
	ip := net.ParseIP(ipStr).To4()
	resp = append(resp, ip...)

	_, _ = conn.WriteToUDP(resp, addr)

	atomic.AddUint64(&statTxPackets, 1)
	atomic.AddUint64(&statTxA, 1)
}

// sendAAAABytesResponse packs payload bytes into multiple AAAA answers.
// Each AAAA carries 1-byte index + 15 bytes payload. Last chunk is zero-padded.
func sendAAAABytesResponse(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain string, payload []byte, qclass uint16) {
	ips := packBytesToIPv6(payload)
	resp := buildBaseResponse(txID, domain, QTYPE_AAAA, qclass, uint16(len(ips)))

	for _, ip16 := range ips {
		resp = append(resp,
			0xc0, 0x0c, // NAME ptr
			0x00, 0x1c, // TYPE AAAA
			0x00, 0x01, // CLASS IN
			0x00, 0x00, 0x00, 0x00, // TTL 0
			0x00, 0x10, // RDLEN 16
		)
		resp = append(resp, ip16[:]...)
	}

	_, _ = conn.WriteToUDP(resp, addr)

	atomic.AddUint64(&statTxPackets, 1)
	atomic.AddUint64(&statTxAAAA, 1)
}

// sendABytesResponse packs payload bytes into multiple A answers (fallback).
// Each A carries 1-byte index + 3 bytes payload. Last chunk is zero-padded.
func sendABytesResponse(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain string, payload []byte, qclass uint16) {
	ips := packBytesToIPv4(payload)
	resp := buildBaseResponse(txID, domain, QTYPE_A, qclass, uint16(len(ips)))

	for _, ip4 := range ips {
		resp = append(resp,
			0xc0, 0x0c, // NAME ptr
			0x00, 0x01, // TYPE A
			0x00, 0x01, // CLASS IN
			0x00, 0x00, 0x00, 0x00, // TTL 0
			0x00, 0x04, // RDLEN 4
		)
		resp = append(resp, ip4[:]...)
	}

	_, _ = conn.WriteToUDP(resp, addr)

	atomic.AddUint64(&statTxPackets, 1)
	atomic.AddUint64(&statTxAPay, 1)
}

// Legacy TXT (kept but unused)
func sendTxtResponse(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain, payload string, qtype, qclass uint16) {
	resp := buildBaseResponse(txID, domain, qtype, qclass, 1)
	resp = append(resp,
		0xc0, 0x0c,
		0x00, 0x10,
		0x00, 0x01,
		0x00, 0x00, 0x00, 0x00,
	)
	rdlen := make([]byte, 2)
	binary.BigEndian.PutUint16(rdlen, uint16(1+len(payload)))
	resp = append(resp, rdlen...)
	resp = append(resp, byte(len(payload)))
	resp = append(resp, []byte(payload)...)

	_, _ = conn.WriteToUDP(resp, addr)

	atomic.AddUint64(&statTxPackets, 1)
	atomic.AddUint64(&statTxTXT, 1)
}

// ───────────────────────── Packing Helpers ─────────────────────────

// packBytesToIPv6 splits data into 15-byte chunks with a 1-byte index prefix.
func packBytesToIPv6(b []byte) [][16]byte {
	if len(b) == 0 {
		// represent empty as single all-zero AAAA
		return [][16]byte{{}}
	}
	chunks := (len(b) + 14) / 15
	if chunks > 255 {
		chunks = 255
	}
	out := make([][16]byte, 0, chunks)
	for i := 0; i < chunks; i++ {
		var ip [16]byte
		ip[0] = byte(i + 1)
		start := i * 15
		end := start + 15
		if end > len(b) {
			end = len(b)
		}
		copy(ip[1:], b[start:end])
		out = append(out, ip)
	}
	return out
}

// packBytesToIPv4 splits data into 3-byte chunks with a 1-byte index prefix.
func packBytesToIPv4(b []byte) [][4]byte {
	if len(b) == 0 {
		return [][4]byte{{}}
	}
	chunks := (len(b) + 2) / 3
	if chunks > 255 {
		chunks = 255
	}
	out := make([][4]byte, 0, chunks)
	for i := 0; i < chunks; i++ {
		var ip [4]byte
		ip[0] = byte(i + 1)
		start := i * 3
		end := start + 3
		if end > len(b) {
			end = len(b)
		}
		copy(ip[1:], b[start:end])
		out = append(out, ip)
	}
	return out
}

// ───────────────────────── Utils ─────────────────────────

func isBase32ID(s string) bool {
	if len(s) != 5 {
		return false
	}
	for _, r := range s {
		if r < 'a' || r > 'z' {
			if r < '2' || r > '7' {
				return false
			}
		}
	}
	return true
}

func atoiSafe(s string) int {
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	return n
}

func preview(s string) string {
	if s == "" {
		return ""
	}
	if len(s) <= PAYLOAD_PREVIEW {
		return s
	}
	return s[:PAYLOAD_PREVIEW] + "…"
}
