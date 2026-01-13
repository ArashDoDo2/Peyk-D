package main

import (
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"time"
)

const (
	LISTEN_IP   = "0.0.0.0"
	LISTEN_PORT = 53
	BASE_DOMAIN = "p99.peyk-d.ir"

	ACK_IP = "3.4.0.0" // ✓  server-received (must match client _isAck)
)

// ───────────────────────── Memory Store ─────────────────────────

// ChunkEnvelope = "idx-tot-sid-rid-payload"
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
	// payload is TXT: "ACK2-<sid>-<tot>"  (sid is sender)
	deliveryAcks = make(map[string][]string)

	storeMu sync.Mutex
)

// TTL for stale chunks
const MESSAGE_TTL = 2 * time.Minute

func main() {
	addr := net.UDPAddr{Port: LISTEN_PORT, IP: net.ParseIP(LISTEN_IP)}
	conn, err := net.ListenUDP("udp", &addr)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()

	go garbageCollector()

	fmt.Println("🚀 [PEYK-D SERVER] In-Memory DNS server listening on UDP/53")

	buf := make([]byte, 512)
	for {
		n, remoteAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		// copy (buf reused)
		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		go handlePacket(conn, remoteAddr, pkt)
	}
}

// ───────────────────────── DNS Question Parsing ─────────────────────────

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

// minimal QNAME parser (no compression; ok for your client)
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
		if (msg[i] & 0xC0) == 0xC0 { // compression pointer not supported here
			return "", 0, false
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
	q, ok := parseQuestion(data)
	if !ok {
		return
	}
	domain := q.QName
	if !strings.HasSuffix(domain, BASE_DOMAIN) {
		return
	}

	txID := data[:2]

	// Polling must be TXT query: v1.sync.<rid>.<base>
	if strings.HasPrefix(domain, "v1.sync.") {
		if q.QType != 16 { // TXT
			return
		}
		handlePolling(conn, addr, txID, domain, q.QType, q.QClass)
		return
	}

	// Inbound send + ACK2 must be A query
	if q.QType != 1 { // A
		return
	}
	handleInboundOrAck2(conn, addr, txID, domain, q.QType, q.QClass)
}

// ───────────────────────── Inbound (Send) + ACK2 ─────────────────────────
// 1) Send chunks: idx-tot-sid-rid-payload.<base>
// 2) Delivery ack (from receiver): ack2-sid-tot.<base>  (sid = original sender)

func handleInboundOrAck2(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain string, qtype, qclass uint16) {
	prefix := strings.TrimSuffix(domain, "."+BASE_DOMAIN)

	// ACK2 path
	// ack2-<sid>-<tot>.<base>
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

		// queue ACK2 for sender polling
		storeMu.Lock()
		deliveryAcks[sid] = append(deliveryAcks[sid], fmt.Sprintf("ACK2-%s-%d", sid, tot))
		storeMu.Unlock()

		// ACK back to receiver (just confirmation of receipt of ack2)
		sendAResponse(conn, addr, txID, domain, ACK_IP, qtype, qclass)
		return
	}

	// Normal inbound chunk
	labels := strings.Split(prefix, "-")
	if len(labels) < 5 {
		return
	}

	idx := atoiSafe(labels[0])
	tot := atoiSafe(labels[1])
	sid := strings.ToLower(labels[2])
	rid := strings.ToLower(labels[3])
	payload := strings.Join(labels[4:], "-")

	if idx <= 0 || tot <= 0 || idx > tot {
		return
	}
	if payload == "" {
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

	storeMu.Lock()
	defer storeMu.Unlock()

	if messageStore[rid] == nil {
		messageStore[rid] = make(map[string][]ChunkEnvelope)
	}

	// idempotency: avoid duplicate chunk
	exists := false
	for _, c := range messageStore[rid][key] {
		if c.Idx == env.Idx && c.Payload == env.Payload {
			exists = true
			break
		}
	}
	if !exists {
		messageStore[rid][key] = append(messageStore[rid][key], env)
		fmt.Printf("📩 RX %s → %s chunk %d/%d\n", sid, rid, idx, tot)
	}

	// ✓ ACK: server received the chunk
	sendAResponse(conn, addr, txID, domain, ACK_IP, qtype, qclass)
}

// ───────────────────────── Polling (Receive) ─────────────────────────
// v1.sync.<rid>.<base>  (TXT query)
// Priority: ACK2 first, then data chunks, else NOP

func handlePolling(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain string, qtype, qclass uint16) {
	parts := strings.Split(domain, ".")
	if len(parts) < 3 {
		return
	}
	rid := strings.ToLower(parts[2])

	storeMu.Lock()
	defer storeMu.Unlock()

	// 1) If there are delivery ACK2s queued for this rid (as sender), send them first
	if acks, ok := deliveryAcks[rid]; ok && len(acks) > 0 {
		ack := acks[0]
		if len(acks) == 1 {
			delete(deliveryAcks, rid)
		} else {
			deliveryAcks[rid] = acks[1:]
		}
		sendTxtResponse(conn, addr, txID, domain, ack, qtype, qclass)
		return
	}

	// 2) Otherwise send message chunks for this rid (as receiver)
	msgs, ok := messageStore[rid]
	if !ok || len(msgs) == 0 {
		sendTxtResponse(conn, addr, txID, domain, "NOP", qtype, qclass)
		return
	}

	// pick oldest messageKey by earliest chunk AddedAt
	var chosenKey string
	var chosenChunks []ChunkEnvelope
	var oldest time.Time

	for k, chunks := range msgs {
		for _, c := range chunks {
			if oldest.IsZero() || c.AddedAt.Before(oldest) {
				oldest = c.AddedAt
				chosenKey = k
				chosenChunks = chunks
			}
		}
	}

	if len(chosenChunks) == 0 {
		sendTxtResponse(conn, addr, txID, domain, "NOP", qtype, qclass)
		return
	}

	// send smallest idx first
	minIdx := int(^uint(0) >> 1)
	var chosen ChunkEnvelope
	for _, c := range chosenChunks {
		if c.Idx < minIdx {
			minIdx = c.Idx
			chosen = c
		}
	}

	full := fmt.Sprintf("%d-%d-%s-%s-%s", chosen.Idx, chosen.Tot, chosen.SID, chosen.RID, chosen.Payload)

	// TXT single string max 255
	if len(full) > 255 {
		full = full[:255]
	}

	fmt.Printf("📦 TX → %s chunk %d/%d\n", rid, chosen.Idx, chosen.Tot)

	sendTxtResponse(conn, addr, txID, domain, full, qtype, qclass)

	// remove delivered chunk from store (server assumes delivered-to-client when polled)
	remaining := make([]ChunkEnvelope, 0, len(chosenChunks)-1)
	for _, c := range chosenChunks {
		if c.Idx != chosen.Idx {
			remaining = append(remaining, c)
		}
	}
	if len(remaining) == 0 {
		delete(messageStore[rid], chosenKey)
		if len(messageStore[rid]) == 0 {
			delete(messageStore, rid)
		}
	} else {
		messageStore[rid][chosenKey] = remaining
	}
}

// ───────────────────────── Garbage Collector ─────────────────────────

func garbageCollector() {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		now := time.Now()

		storeMu.Lock()

		// clear stale chunks
		for rid, msgs := range messageStore {
			for key, chunks := range msgs {
				filtered := make([]ChunkEnvelope, 0, len(chunks))
				for _, c := range chunks {
					if now.Sub(c.AddedAt) < MESSAGE_TTL {
						filtered = append(filtered, c)
					}
				}
				if len(filtered) == 0 {
					delete(msgs, key)
				} else {
					msgs[key] = filtered
				}
			}
			if len(msgs) == 0 {
				delete(messageStore, rid)
			}
		}

		// clear stale ACK2 queue entries (optional: keep short)
		// Here we don't timestamp ACK2; if you want TTL, store struct with AddedAt.

		storeMu.Unlock()
	}
}

// ───────────────────────── DNS Builders ─────────────────────────

func buildBaseResponse(txID []byte, domain string, qtype, qclass uint16, ancount uint16) []byte {
	resp := make([]byte, 0, 512)

	// TXID
	resp = append(resp, txID[0], txID[1])

	// Flags: standard response, no error
	resp = append(resp, 0x81, 0x80)

	// QDCOUNT=1
	resp = append(resp, 0x00, 0x01)

	// ANCOUNT
	resp = append(resp, byte(ancount>>8), byte(ancount))

	// NSCOUNT=0, ARCOUNT=0
	resp = append(resp, 0x00, 0x00, 0x00, 0x00)

	// QNAME
	for _, label := range strings.Split(domain, ".") {
		if label == "" {
			continue
		}
		if len(label) > 63 {
			return nil
		}
		resp = append(resp, byte(len(label)))
		resp = append(resp, []byte(label)...)
	}
	resp = append(resp, 0x00)

	// QTYPE/QCLASS echo (critical)
	tmp := make([]byte, 4)
	binary.BigEndian.PutUint16(tmp[0:2], qtype)
	binary.BigEndian.PutUint16(tmp[2:4], qclass)
	resp = append(resp, tmp...)

	return resp
}

func sendAResponse(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain, ipStr string, qtype, qclass uint16) {
	resp := buildBaseResponse(txID, domain, qtype, qclass, 1)
	if resp == nil {
		return
	}

	resp = append(resp,
		0xc0, 0x0c, // NAME pointer
		0x00, 0x01, // TYPE A
		0x00, 0x01, // CLASS IN
		0x00, 0x00, 0x00, 0x1e, // TTL 30
		0x00, 0x04, // RDLENGTH 4
	)

	ip := net.ParseIP(ipStr).To4()
	if ip == nil {
		return
	}
	resp = append(resp, ip...)

	_, _ = conn.WriteToUDP(resp, addr)
}

func sendTxtResponse(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain, payload string, qtype, qclass uint16) {
	if len(payload) > 255 {
		payload = payload[:255]
	}

	resp := buildBaseResponse(txID, domain, qtype, qclass, 1)
	if resp == nil {
		return
	}

	resp = append(resp,
		0xc0, 0x0c, // NAME pointer
		0x00, 0x10, // TYPE TXT
		0x00, 0x01, // CLASS IN
		0x00, 0x00, 0x00, 0x00, // TTL 0
	)

	// RDLENGTH = 1 + len(payload)
	rdLen := make([]byte, 2)
	binary.BigEndian.PutUint16(rdLen, uint16(1+len(payload)))
	resp = append(resp, rdLen...)

	resp = append(resp, byte(len(payload)))
	resp = append(resp, []byte(payload)...)

	_, _ = conn.WriteToUDP(resp, addr)
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
