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
	MESSAGE_TTL       = 2 * time.Minute
	PAYLOAD_PREVIEW   = 24 // chars
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
	SID     string
	RID     string
	Payload string
	AddedAt time.Time
}

// messageStore:
// map[receiverID]map[messageKey][]ChunkEnvelope
// messageKey = sid + ":" + tot
var (
	messageStore = make(map[string]map[string][]ChunkEnvelope)

	// deliveryAcks: map[senderID][]string
	// payload: "ACK2-<sid>-<tot>"
	deliveryAcks = make(map[string][]string)

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

	log.Printf("🚀 [PEYK-D SERVER — DEBUG] Listening on %s:%d (UDP)\n", LISTEN_IP, LISTEN_PORT)

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

	log.Printf("📥 RX pkt from=%s txid=%s qtype=%d qname=%s", addr.String(), txIDHex, q.QType, domain)

	// Polling (NOW: AAAA preferred, fallback to A)
	if strings.HasPrefix(domain, "v1.sync.") {
		// Allow AAAA (28) and A (1). Ignore TXT now.
		if q.QType != QTYPE_AAAA && q.QType != QTYPE_A {
			atomic.AddUint64(&statIgnored, 1)
			return
		}
		atomic.AddUint64(&statPollRequests, 1)
		handlePolling(conn, addr, txID, domain, q.QType, q.QClass)
		log.Printf("⏱️  done poll from=%s txid=%s took=%s", addr.String(), txIDHex, time.Since(start))
		return
	}

	// Inbound chunk or ACK2 (A)
	if q.QType != QTYPE_A {
		atomic.AddUint64(&statIgnored, 1)
		return
	}
	handleInboundOrAck2(conn, addr, txID, domain, q.QType, q.QClass)
	log.Printf("⏱️  done A from=%s txid=%s took=%s", addr.String(), txIDHex, time.Since(start))
}

// ───────────────────────── Inbound + ACK2 ─────────────────────────

func handleInboundOrAck2(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain string, qtype, qclass uint16) {
	prefix := strings.TrimSuffix(domain, "."+BASE_DOMAIN)

	// ACK2: ack2-sid-tot
	if strings.HasPrefix(prefix, "ack2-") {
		parts := strings.Split(prefix, "-")
		if len(parts) != 3 {
			return
		}
		sid := strings.ToLower(parts[1])
		tot := atoiSafe(parts[2])
		if tot <= 0 {
			return
		}

		storeMu.Lock()
		deliveryAcks[sid] = append(deliveryAcks[sid], fmt.Sprintf("ACK2-%s-%d", sid, tot))
		queueLen := len(deliveryAcks[sid])
		storeMu.Unlock()

		atomic.AddUint64(&statRxAck2, 1)
		log.Printf("✅ ACK2 stored sid=%s tot=%d (queue=%d) from=%s", sid, tot, queueLen, addr.String())

		// Keep ACK response as A with fixed ACK_IP (unchanged)
		sendAResponse(conn, addr, txID, domain, ACK_IP, qtype, qclass)
		return
	}

	// Chunk: idx-tot-sid-rid-payload
	labels := strings.Split(prefix, "-")
	if len(labels) < 5 {
		return
	}

	idx := atoiSafe(labels[0])
	tot := atoiSafe(labels[1])
	sid := strings.ToLower(labels[2])
	rid := strings.ToLower(labels[3])
	payload := strings.Join(labels[4:], "-")

	if idx <= 0 || tot <= 0 || idx > tot || payload == "" {
		return
	}

	env := ChunkEnvelope{
		Idx:     idx,
		Tot:     tot,
		SID:     sid,
		RID:     rid,
		Payload: payload,
		AddedAt: time.Now(),
	}

	key := fmt.Sprintf("%s:%d", sid, tot)

	var (
		dup     bool
		msgSize int
	)

	storeMu.Lock()
	if messageStore[rid] == nil {
		messageStore[rid] = make(map[string][]ChunkEnvelope)
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
	storeMu.Unlock()

	if dup {
		atomic.AddUint64(&statRxDupChunks, 1)
		log.Printf("⚠️  DUP chunk sid=%s->%s %d/%d from=%s", sid, rid, idx, tot, addr.String())
	} else {
		atomic.AddUint64(&statRxChunks, 1)
		log.Printf("📩 RX chunk sid=%s->%s %d/%d payloadLen=%d key=%s chunksInKey=%d preview=%q",
			sid, rid, idx, tot, len(payload), key, msgSize, preview(payload))
	}

	// ACK for inbound chunk remains A
	sendAResponse(conn, addr, txID, domain, ACK_IP, qtype, qclass)
}

// ───────────────────────── Polling ─────────────────────────

func handlePolling(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain string, qtype, qclass uint16) {
	parts := strings.Split(domain, ".")
	if len(parts) < 3 {
		log.Printf("🟦 poll malformed qname=%s from=%s -> NOP", domain, addr.String())
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

		log.Printf("🟩 poll rid=%s from=%s -> ACK2 (%s) remaining=%d viaQ=%d", rid, addr.String(), ack, remaining, qtype)
		sendPollingPayload(conn, addr, txID, domain, ack, qtype, qclass)
		return
	}

	// 2) Chunks
	msgs, ok := messageStore[rid]
	if !ok || len(msgs) == 0 {
		storeMu.Unlock()
		log.Printf("🟨 poll rid=%s from=%s -> NOP (no msgs) viaQ=%d", rid, addr.String(), qtype)
		sendPollingPayload(conn, addr, txID, domain, "NOP", qtype, qclass)
		return
	}

	for key, chunks := range msgs {
		c := chunks[0]
		full := fmt.Sprintf("%d-%d-%s-%s-%s", c.Idx, c.Tot, c.SID, c.RID, c.Payload)

		// NOTE: We no longer have TXT 255 limitation; keep a sane cap anyway to avoid huge DNS responses.
		// 480 bytes cap keeps us safe under typical 512-byte UDP DNS while still useful.
		if len(full) > 480 {
			full = full[:480]
		}

		// delete immediately (no resend)
		if len(chunks) == 1 {
			delete(msgs, key)
			if len(msgs) == 0 {
				delete(messageStore, rid)
			}
		} else {
			msgs[key] = chunks[1:]
		}
		leftInKey := len(msgs[key])
		storeMu.Unlock()

		log.Printf("🟧 poll rid=%s from=%s -> CHUNK key=%s sent=%d/%d sid=%s payloadLen=%d leftInKey=%d viaQ=%d preview=%q",
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
		storeMu.Unlock()

		if expired > 0 || keysRemoved > 0 || ridsRemoved > 0 {
			log.Printf("🧹 GC expired=%d chunks (before=%d after=%d) keysRemoved=%d ridsRemoved=%d ttl=%s",
				expired, beforeChunks, afterChunks, keysRemoved, ridsRemoved, MESSAGE_TTL)
		}
	}
}

// ───────────────────────── Stats Logger ─────────────────────────

func statsLogger() {
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
// Each AAAA carries 16 bytes. Last chunk is zero-padded; client should trim by parsing payload format.
// (Since payload is ASCII and format-delimited, padding zeros at the end is safe if client trims trailing \x00.)
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
// Each A carries 4 bytes. Last chunk is zero-padded similarly.
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

// packBytesToIPv6 splits data into 16-byte chunks. last chunk is zero-padded.
func packBytesToIPv6(b []byte) [][16]byte {
	if len(b) == 0 {
		// represent empty as single all-zero AAAA (client can treat as "NOP" only if it wants; we won't send empty anyway)
		return [][16]byte{{}}
	}
	chunks := (len(b) + 15) / 16
	out := make([][16]byte, 0, chunks)
	for i := 0; i < chunks; i++ {
		var ip [16]byte
		start := i * 16
		end := start + 16
		if end > len(b) {
			end = len(b)
		}
		copy(ip[:], b[start:end])
		out = append(out, ip)
	}
	return out
}

// packBytesToIPv4 splits data into 4-byte chunks. last chunk is zero-padded.
func packBytesToIPv4(b []byte) [][4]byte {
	if len(b) == 0 {
		return [][4]byte{{}}
	}
	chunks := (len(b) + 3) / 4
	out := make([][4]byte, 0, chunks)
	for i := 0; i < chunks; i++ {
		var ip [4]byte
		start := i * 4
		end := start + 4
		if end > len(b) {
			end = len(b)
		}
		copy(ip[:], b[start:end])
		out = append(out, ip)
	}
	return out
}

// ───────────────────────── Utils ─────────────────────────

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
