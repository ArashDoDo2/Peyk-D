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
	BASE_DOMAIN = "p99.online.ir"

	ACK_IP = "3.4.0.0" // server-received ACK
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

const MESSAGE_TTL = 2 * time.Minute

func main() {
	addr := net.UDPAddr{Port: LISTEN_PORT, IP: net.ParseIP(LISTEN_IP)}
	conn, err := net.ListenUDP("udp", &addr)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()

	go garbageCollector()

	fmt.Println("🚀 [PEYK-D SERVER — STABLE] Listening on UDP/53")

	buf := make([]byte, 512)
	for {
		n, remoteAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}
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
	q, ok := parseQuestion(data)
	if !ok {
		return
	}

	domain := strings.ToLower(q.QName)
	if !strings.HasSuffix(domain, BASE_DOMAIN) {
		return
	}

	txID := data[:2]

	// Polling (TXT)
	if strings.HasPrefix(domain, "v1.sync.") {
		if q.QType != 16 {
			return
		}
		handlePolling(conn, addr, txID, domain, q.QType, q.QClass)
		return
	}

	// Inbound chunk or ACK2 (A)
	if q.QType != 1 {
		return
	}
	handleInboundOrAck2(conn, addr, txID, domain, q.QType, q.QClass)
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
		deliveryAcks[sid] = append(deliveryAcks[sid],
			fmt.Sprintf("ACK2-%s-%d", sid, tot))
		storeMu.Unlock()

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

	storeMu.Lock()
	if messageStore[rid] == nil {
		messageStore[rid] = make(map[string][]ChunkEnvelope)
	}

	exists := false
	for _, c := range messageStore[rid][key] {
		if c.Idx == env.Idx {
			exists = true
			break
		}
	}
	if !exists {
		messageStore[rid][key] = append(messageStore[rid][key], env)
		fmt.Printf("📩 RX %s → %s chunk %d/%d\n", sid, rid, idx, tot)
	}
	storeMu.Unlock()

	sendAResponse(conn, addr, txID, domain, ACK_IP, qtype, qclass)
}

// ───────────────────────── Polling ─────────────────────────

func handlePolling(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain string, qtype, qclass uint16) {
	parts := strings.Split(domain, ".")
	if len(parts) < 3 {
		sendTxtResponse(conn, addr, txID, domain, "NOP", qtype, qclass)
		return
	}
	rid := strings.ToLower(parts[2])

	storeMu.Lock()
	defer storeMu.Unlock()

	// 1) ACK2s
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

	// 2) Chunks
	msgs, ok := messageStore[rid]
	if !ok || len(msgs) == 0 {
		sendTxtResponse(conn, addr, txID, domain, "NOP", qtype, qclass)
		return
	}

	for key, chunks := range msgs {
		c := chunks[0]

		full := fmt.Sprintf("%d-%d-%s-%s-%s",
			c.Idx, c.Tot, c.SID, c.RID, c.Payload)

		if len(full) > 255 {
			full = full[:255]
		}

		sendTxtResponse(conn, addr, txID, domain, full, qtype, qclass)

		// delete immediately (no resend)
		if len(chunks) == 1 {
			delete(msgs, key)
			if len(msgs) == 0 {
				delete(messageStore, rid)
			}
		} else {
			msgs[key] = chunks[1:]
		}
		return
	}
}

// ───────────────────────── GC ─────────────────────────

func garbageCollector() {
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		now := time.Now()
		storeMu.Lock()
		for rid, msgs := range messageStore {
			for key, chunks := range msgs {
				filtered := chunks[:0]
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
		storeMu.Unlock()
	}
}

// ───────────────────────── DNS Builders ─────────────────────────

func buildBaseResponse(txID []byte, domain string, qtype, qclass uint16, ancount uint16) []byte {
	resp := make([]byte, 0, 512)

	resp = append(resp, txID[0], txID[1])
	resp = append(resp, 0x84, 0x00) // QR + AA
	resp = append(resp, 0x00, 0x01)
	resp = append(resp, byte(ancount>>8), byte(ancount))
	resp = append(resp, 0x00, 0x00, 0x00, 0x00)

	for _, label := range strings.Split(domain, ".") {
		if label == "" {
			continue
		}
		resp = append(resp, byte(len(label)))
		resp = append(resp, []byte(label)...)
	}
	resp = append(resp, 0x00)

	tmp := make([]byte, 4)
	binary.BigEndian.PutUint16(tmp[0:2], qtype)
	binary.BigEndian.PutUint16(tmp[2:4], qclass)
	resp = append(resp, tmp...)

	return resp
}

func sendAResponse(conn *net.UDPConn, addr *net.UDPAddr, txID []byte, domain, ipStr string, qtype, qclass uint16) {
	resp := buildBaseResponse(txID, domain, qtype, qclass, 1)
	resp = append(resp,
		0xc0, 0x0c,
		0x00, 0x01,
		0x00, 0x01,
		0x00, 0x00, 0x00, 0x1e,
		0x00, 0x04,
	)
	ip := net.ParseIP(ipStr).To4()
	resp = append(resp, ip...)
	conn.WriteToUDP(resp, addr)
}

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
	conn.WriteToUDP(resp, addr)
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
