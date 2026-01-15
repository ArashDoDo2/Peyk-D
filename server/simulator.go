package main

import (
	"bufio"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	BASE_DOMAIN = "p99.online.ir"
	PASSPHRASE  = "my-fixed-passphrase-change-me"

	MY_ID     = "simul"
	TARGET_ID = "a3akc"

	// Direct server IP for DNS queries (bypasses recursive DNS)
	// Set to empty string "" to use system recursive DNS instead
	DIRECT_SERVER_IP   = ""
	DIRECT_SERVER_PORT = 53

	// Fallback to A only when enabled and no response received
	ENABLE_A_FALLBACK = false
)

// RX buffers: key = "sid-rid-tot" -> idx->payload
var (
	buffers   = make(map[string]map[int]string)
	buffersMu sync.Mutex
)

// Dedup store: key = "sid:<hash>" with TTL (prevents false duplicate based on tot)
var (
	seenMu     sync.Mutex
	seenHashAt = make(map[string]time.Time)
	seenTTL    = 10 * time.Minute
)

// ✅ Peyk latency metrics (TX start → ACK2 received)
// key = "<sid>:<tot>"  (sid is sender; for our outgoing messages sid=MY_ID)
var (
	txMu      sync.Mutex
	txStartAt = make(map[string]time.Time)
)

// IPv4-only resolver to avoid Windows AAAA timeout (~10s)
var resolver4 = &net.Resolver{
	PreferGo: true,
	Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		d := net.Dialer{Timeout: 1200 * time.Millisecond}
		return d.DialContext(ctx, "udp4", address)
	},
}

func generateID() string {
	const chars = "abcdefghijklmnopqrstuvwxyz234567"
	b := make([]byte, 5)
	seed := time.Now().UnixNano()
	for i := 0; i < 5; i++ {
		seed = (seed*1664525 + 1013904223) & 0x7fffffff
		b[i] = chars[seed%int64(len(chars))]
	}
	return string(b)
}

func main() {
	fmt.Println("🚀 Peyk Simulator Pro [AAAA/A Mode] Started...")
	fmt.Printf("🆔 My ID: %s | 🎯 Target ID: %s\n", MY_ID, TARGET_ID)
	if DIRECT_SERVER_IP != "" {
		fmt.Printf("🌐 DIRECT mode: sending to %s:%d\n", DIRECT_SERVER_IP, DIRECT_SERVER_PORT)
	} else {
		fmt.Println("🌐 RECURSIVE mode: using system DNS resolver")
	}
	fmt.Println("--------------------------------------------------")

	go startPolling()

	fmt.Println("💬 Type your message and press Enter to send:")
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		msg := scanner.Text()
		if strings.TrimSpace(msg) != "" {
			sendManualMessage(msg)
		}
	}
}

// ───────────────────────── POLLING (RX) ─────────────────────────

func startPolling() {
	const (
		fastDelay   = 350 * time.Millisecond
		minBackoff  = 1500 * time.Millisecond
		maxBackoff  = 5 * time.Second
		backoffStep = 1.5
	)

	backoff := minBackoff

	for {
		queryDomain := fmt.Sprintf("v1.sync.%s.%s.%s", MY_ID, generateID(), BASE_DOMAIN)

		var txt string

		if DIRECT_SERVER_IP != "" {
			// Direct mode: send raw DNS query to Peyk server
			txt = pollDirect(queryDomain)
		} else {
			// Recursive mode (fallback)
			txt = pollRecursive(queryDomain)
		}

		if txt == "" || txt == "NOP" {
			time.Sleep(backoff)
			backoff = time.Duration(float64(backoff) * backoffStep)
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
			continue
		}

		backoff = minBackoff

		if strings.HasPrefix(txt, "ACK2-") {
			fmt.Println("✅ [ACK2 RECEIVED]", txt)
			handleAck2Metric(txt)
		} else {
			handleIncomingChunk(txt)
		}

		time.Sleep(fastDelay)
	}
}

// pollDirect sends raw DNS query directly to Peyk server
func pollDirect(domain string) string {
	addr := fmt.Sprintf("%s:%d", DIRECT_SERVER_IP, DIRECT_SERVER_PORT)
	conn, err := net.DialTimeout("udp", addr, 1500*time.Millisecond)
	if err != nil {
		return ""
	}
	defer conn.Close()

	// Try AAAA first
	query := buildDNSQuery(domain, 28) // AAAA
	conn.SetDeadline(time.Now().Add(1500 * time.Millisecond))
	_, err = conn.Write(query)
	if err != nil {
		return ""
	}

	buf := make([]byte, 512)
	n, err := conn.Read(buf)
	if err == nil && n > 12 {
		txt := extractPayloadFromDNSResponse(buf[:n])
		if txt != "" {
			return txt
		}
		if !ENABLE_A_FALLBACK {
			return ""
		}
	} else if !ENABLE_A_FALLBACK {
		return ""
	}

	// Fallback to A (only if enabled)
	query = buildDNSQuery(domain, 1) // A
	conn.SetDeadline(time.Now().Add(1500 * time.Millisecond))
	_, err = conn.Write(query)
	if err != nil {
		return ""
	}

	n, err = conn.Read(buf)
	if err == nil && n > 12 {
		return extractPayloadFromDNSResponse(buf[:n])
	}

	return ""
}

// pollRecursive uses system DNS resolver (legacy)
func pollRecursive(domain string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	ips, err := resolver4.LookupIP(ctx, "ip6", domain)
	cancel()

	if err == nil && len(ips) > 0 {
		txt := extractPayloadFromIPs(ips)
		if txt != "" {
			return txt
		}
		if !ENABLE_A_FALLBACK {
			return ""
		}
	} else if !ENABLE_A_FALLBACK {
		return ""
	}

	// Fallback to A (only if enabled)
	ctx2, cancel2 := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	ips4, err4 := resolver4.LookupIP(ctx2, "ip4", domain)
	cancel2()

	if err4 == nil && len(ips4) > 0 {
		return extractPayloadFromIPs(ips4)
	}

	return ""
}

// buildDNSQuery creates a raw DNS query packet
func buildDNSQuery(domain string, qtype uint16) []byte {
	buf := make([]byte, 0, 512)

	// Transaction ID (random)
	txid := uint16(time.Now().UnixNano() & 0xFFFF)
	buf = append(buf, byte(txid>>8), byte(txid&0xFF))

	// Flags: Standard query, recursion desired
	buf = append(buf, 0x01, 0x00)

	// QDCOUNT=1, ANCOUNT=0, NSCOUNT=0, ARCOUNT=0
	buf = append(buf, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

	// QNAME
	for _, label := range strings.Split(domain, ".") {
		if label == "" {
			continue
		}
		buf = append(buf, byte(len(label)))
		buf = append(buf, []byte(label)...)
	}
	buf = append(buf, 0x00) // null terminator

	// QTYPE
	buf = append(buf, byte(qtype>>8), byte(qtype&0xFF))

	// QCLASS: IN
	buf = append(buf, 0x00, 0x01)

	return buf
}

// extractPayloadFromDNSResponse extracts payload bytes from DNS response
func extractPayloadFromDNSResponse(data []byte) string {
	if len(data) < 12 {
		return ""
	}

	// ANCOUNT
	ancount := int(data[6])<<8 | int(data[7])
	if ancount == 0 {
		return ""
	}

	// Skip header (12 bytes)
	i := 12

	// Skip question section
	for i < len(data) && data[i] != 0 {
		if data[i]&0xC0 == 0xC0 {
			i += 2
			break
		}
		i += int(data[i]) + 1
	}
	if i < len(data) && data[i] == 0 {
		i++
	}
	i += 4 // QTYPE + QCLASS

	var legacy []byte
	indexed := make(map[byte][]byte)
	hasIndex0 := false

	// Parse answers
	for a := 0; a < ancount && i+10 <= len(data); a++ {
		// Skip NAME
		if data[i]&0xC0 == 0xC0 {
			i += 2
		} else {
			for i < len(data) && data[i] != 0 {
				i += int(data[i]) + 1
			}
			if i < len(data) {
				i++
			}
		}

		if i+10 > len(data) {
			break
		}

		rtype := int(data[i])<<8 | int(data[i+1])
		i += 8 // TYPE + CLASS + TTL

		rdlen := int(data[i])<<8 | int(data[i+1])
		i += 2

		if i+rdlen > len(data) {
			break
		}

		// A (4 bytes) or AAAA (16 bytes)
		if rtype == 1 || rtype == 28 {
			raw := data[i : i+rdlen]
			legacy = append(legacy, raw...)
			if len(raw) >= 2 && raw[0] > 0 {
				idx := raw[0] - 1
				if _, ok := indexed[idx]; !ok {
					indexed[idx] = append([]byte{}, raw[1:]...)
					if idx == 0 {
						hasIndex0 = true
					}
				}
			}
		}

		i += rdlen
	}

	payload := legacy
	if len(indexed) > 0 && hasIndex0 {
		keys := make([]int, 0, len(indexed))
		for k := range indexed {
			keys = append(keys, int(k))
		}
		sort.Ints(keys)
		var rebuilt []byte
		for _, k := range keys {
			rebuilt = append(rebuilt, indexed[byte(k)]...)
		}
		payload = rebuilt
	}

	// Trim trailing null bytes
	for len(payload) > 0 && payload[len(payload)-1] == 0 {
		payload = payload[:len(payload)-1]
	}

	return string(payload)
}

// extractPayloadFromIPs extracts bytes from IP addresses (for recursive mode)
func extractPayloadFromIPs(ips []net.IP) string {
	var legacy []byte
	indexed := make(map[byte][]byte)
	hasIndex0 := false
	for _, ip := range ips {
		if ip4 := ip.To4(); ip4 != nil {
			legacy = append(legacy, ip4...)
			if len(ip4) >= 2 && ip4[0] > 0 {
				idx := ip4[0] - 1
				if _, ok := indexed[idx]; !ok {
					indexed[idx] = append([]byte{}, ip4[1:]...)
					if idx == 0 {
						hasIndex0 = true
					}
				}
			}
		} else if ip16 := ip.To16(); ip16 != nil {
			legacy = append(legacy, ip16...)
			if len(ip16) >= 2 && ip16[0] > 0 {
				idx := ip16[0] - 1
				if _, ok := indexed[idx]; !ok {
					indexed[idx] = append([]byte{}, ip16[1:]...)
					if idx == 0 {
						hasIndex0 = true
					}
				}
			}
		}
	}

	buf := legacy
	if len(indexed) > 0 && hasIndex0 {
		keys := make([]int, 0, len(indexed))
		for k := range indexed {
			keys = append(keys, int(k))
		}
		sort.Ints(keys)
		var rebuilt []byte
		for _, k := range keys {
			rebuilt = append(rebuilt, indexed[byte(k)]...)
		}
		buf = rebuilt
	}
	// Trim trailing null bytes
	for len(buf) > 0 && buf[len(buf)-1] == 0 {
		buf = buf[:len(buf)-1]
	}
	return string(buf)
}

// sendDirectDNSQuery sends a DNS query directly to the Peyk server (fire and forget)
func sendDirectDNSQuery(domain string, qtype uint16) {
	addr := fmt.Sprintf("%s:%d", DIRECT_SERVER_IP, DIRECT_SERVER_PORT)
	conn, err := net.DialTimeout("udp", addr, 1500*time.Millisecond)
	if err != nil {
		return
	}
	defer conn.Close()

	query := buildDNSQuery(domain, qtype)
	conn.SetDeadline(time.Now().Add(1500 * time.Millisecond))
	conn.Write(query)

	// Wait for response (to get ACK from server)
	buf := make([]byte, 512)
	conn.Read(buf)
}

// ✅ Parse ACK2 and compute Peyk latency if it's for our outgoing message
func handleAck2Metric(txt string) {
	// format: ACK2-<sid>-<tot> or ACK2-<sid>-<tot>-<mid>
	parts := strings.Split(txt, "-")
	if len(parts) != 3 && len(parts) != 4 {
		return
	}

	sid := strings.ToLower(parts[1])
	tot, err := strconv.Atoi(parts[2])
	if err != nil || tot <= 0 {
		return
	}
	mid := ""
	if len(parts) == 4 {
		mid = strings.ToLower(parts[3])
	}

	key := ""
	if mid != "" {
		key = fmt.Sprintf("%s:%d:%s", sid, tot, mid)
	} else {
		key = fmt.Sprintf("%s:%d", sid, tot)
	}

	txMu.Lock()
	start, ok := txStartAt[key]
	if ok {
		delete(txStartAt, key)
	}
	txMu.Unlock()

	if !ok {
		// no start time recorded (maybe old ACK2 or collision)
		return
	}

	lat := time.Since(start)
	fmt.Printf("📊 PEYK_LATENCY sid=%s tot=%d latency=%s\n", sid, tot, lat.Round(time.Millisecond))
}

// ───────────────────────── RX CHUNKS ─────────────────────────

func handleIncomingChunk(txt string) {
	parts := strings.Split(txt, "-")
	if len(parts) < 5 {
		return
	}

	var idx, total int
	if _, err := fmt.Sscanf(parts[0], "%d", &idx); err != nil {
		return
	}
	if _, err := fmt.Sscanf(parts[1], "%d", &total); err != nil {
		return
	}

	mid := ""
	senderID := ""
	receiverID := ""
	payload := ""

	if len(parts) >= 6 && len(parts[2]) == 5 && len(parts[3]) == 5 && len(parts[4]) == 5 {
		mid = strings.ToLower(parts[2])
		senderID = strings.ToLower(parts[3])
		receiverID = strings.ToLower(parts[4])
		payload = strings.Join(parts[5:], "-")
	} else {
		senderID = strings.ToLower(parts[2])
		receiverID = strings.ToLower(parts[3])
		payload = strings.Join(parts[4:], "-")
	}

	if receiverID != strings.ToLower(MY_ID) {
		return
	}
	if idx <= 0 || total <= 0 || idx > total || payload == "" {
		return
	}

	key := ""
	if mid != "" {
		key = fmt.Sprintf("%s-%s-%d-%s", senderID, receiverID, total, mid)
	} else {
		key = fmt.Sprintf("%s-%s-%d", senderID, receiverID, total)
	}

	buffersMu.Lock()
	if _, ok := buffers[key]; !ok {
		buffers[key] = make(map[int]string)
	}
	buffers[key][idx] = payload
	got := len(buffers[key])
	buffersMu.Unlock()

	fmt.Printf("📦 [RX] Chunk %d/%d from %s (have %d/%d)\n", idx, total, senderID, got, total)

	if got == total {
		assembleAndDecrypt(key, total, senderID, mid)
	}
}

func assembleAndDecrypt(key string, total int, senderID string, mid string) {
	// copy out under lock
	buffersMu.Lock()
	chunks, ok := buffers[key]
	if !ok {
		buffersMu.Unlock()
		return
	}
	for i := 1; i <= total; i++ {
		if _, exists := chunks[i]; !exists {
			buffersMu.Unlock()
			return
		}
	}

	var sb strings.Builder
	for i := 1; i <= total; i++ {
		sb.WriteString(chunks[i])
	}

	delete(buffers, key)
	buffersMu.Unlock()

	fullB32 := sb.String()

	// ✅ Dedup correctly: hash of message content (not sid:tot)
	msgHash := sha256.Sum256([]byte(fullB32))
	hashHex := hex.EncodeToString(msgHash[:8])
	dupKey := fmt.Sprintf("%s:%s", senderID, hashHex)

	if isDuplicateAndMark(dupKey) {
		fmt.Printf("🔁 DUPLICATE (content-hash) ignored %s\n", dupKey)
		// Still ACK2 (best-effort) to help sender stop resending
		go retryAck2Stable(senderID, total, mid)
		return
	}

	raw, err := base32.StdEncoding.WithPadding(base32.NoPadding).
		DecodeString(strings.ToUpper(fullB32))
	if err != nil {
		fmt.Printf("❌ Base32 Error: %v\n", err)
		return
	}

	decrypted, err := decrypt(raw)
	if err != nil {
		fmt.Printf("❌ Decrypt Error: %v\n", err)
		return
	}

	fmt.Printf("\n📩 NEW MESSAGE [%s]: %s\n\n", senderID, decrypted)

	// ACK2 (stable format: ack2-sid-tot)
	go retryAck2Stable(senderID, total, mid)
}

// Dedup with TTL cleanup
func isDuplicateAndMark(k string) bool {
	now := time.Now()

	seenMu.Lock()
	defer seenMu.Unlock()

	for kk, t := range seenHashAt {
		if now.Sub(t) > seenTTL {
			delete(seenHashAt, kk)
		}
	}

	if t, ok := seenHashAt[k]; ok && now.Sub(t) <= seenTTL {
		return true
	}

	seenHashAt[k] = now
	return false
}

// ───────────────────────── ACK2 (Stable) ─────────────────────────
//
// Send "ack2-<sid>-<tot>.<base>" (no RID) — matches stable server.
// Retry a few times (best-effort) because DNS can drop.

func retryAck2Stable(senderID string, total int, mid string) {
	domain := ""
	if mid != "" {
		domain = fmt.Sprintf("ack2-%s-%d-%s.%s.%s", strings.ToLower(senderID), total, mid, generateID(), BASE_DOMAIN)
	} else {
		domain = fmt.Sprintf("ack2-%s-%d.%s.%s", strings.ToLower(senderID), total, generateID(), BASE_DOMAIN)
	}

	for i := 0; i < 3; i++ {
		if DIRECT_SERVER_IP != "" {
			sendDirectDNSQuery(domain, 28) // AAAA query
		} else {
			ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
			_, _ = resolver4.LookupIP(ctx, "ip4", domain)
			cancel()
		}
		time.Sleep(350 * time.Millisecond)
	}

	if mid != "" {
		fmt.Printf("ACK2 sent for %s/%d mid=%s (stable)\n", senderID, total, mid)
	} else {
		fmt.Printf("ACK2 sent for %s/%d (stable)\n", senderID, total)
	}
}

// ───────────────────────── TX (Send) ─────────────────────────

func sendManualMessage(msg string) {
	hash := sha256.Sum256([]byte(PASSPHRASE))
	key := hash[:]

	block, _ := aes.NewCipher(key)
	aesgcm, _ := cipher.NewGCM(block)

	nonce := make([]byte, 12)
	_, _ = io.ReadFull(rand.Reader, nonce)

	encrypted := aesgcm.Seal(nil, nonce, []byte(msg), nil)
	fullData := append(nonce, encrypted...)

	encoded := strings.ToLower(
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(fullData),
	)

	sendChunks(encoded)
}

func sendChunks(data string) {
	chunkSize := 30 // Match Flutter client chunk size
	total := (len(data) + chunkSize - 1) / chunkSize
	mid := generateID()

	// ✅ record Peyk TX start time for latency metric
	// key is "<MY_ID>:<tot>", matching server ACK2 format: ACK2-<sid>-<tot>
	txKey := fmt.Sprintf("%s:%d:%s", strings.ToLower(MY_ID), total, mid)
	txMu.Lock()
	txStartAt[txKey] = time.Now()
	txMu.Unlock()

	const (
		fastPace = 200 * time.Millisecond
		slowPace = 900 * time.Millisecond
	)

	for i := 0; i < total; i++ {
		start := i * chunkSize
		end := start + chunkSize
		if end > len(data) {
			end = len(data)
		}

		label := fmt.Sprintf("%d-%d-%s-%s-%s-%s", i+1, total, mid, MY_ID, TARGET_ID, data[start:end])
		host := label + "." + BASE_DOMAIN

		startTime := time.Now()
		var err error

		if DIRECT_SERVER_IP != "" {
			// Direct mode
			sendDirectDNSQuery(host, 28) // AAAA query
		} else {
			// Recursive mode
			ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
			_, err = resolver4.LookupIP(ctx, "ip4", host)
			cancel()
		}
		rtt := time.Since(startTime)

		if err != nil {
			fmt.Printf("⚠️ [TX] Chunk %d/%d - SENT (err after %v)\n", i+1, total, rtt.Round(time.Millisecond))
			time.Sleep(slowPace)
		} else {
			fmt.Printf("📤 [TX] Chunk %d/%d - SENT (RTT: %v)\n", i+1, total, rtt.Round(time.Millisecond))
			time.Sleep(fastPace)
		}
	}

	fmt.Println("✅ Message SENT.")
}

// ───────────────────────── Crypto ─────────────────────────

func decrypt(data []byte) (string, error) {
	hash := sha256.Sum256([]byte(PASSPHRASE))
	key := hash[:]

	block, _ := aes.NewCipher(key)
	aesgcm, _ := cipher.NewGCM(block)

	if len(data) < 12+16 {
		return "", fmt.Errorf("data too short")
	}

	nonce := data[:12]
	ciphertext := data[12:]

	plain, err := aesgcm.Open(nil, nonce, ciphertext, nil)
	return string(plain), err
}
