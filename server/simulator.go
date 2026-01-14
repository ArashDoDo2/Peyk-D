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

func main() {
	fmt.Println("🚀 Peyk Simulator Pro [RECURSIVE MODE - IPv4 ONLY] Started...")
	fmt.Printf("🆔 My ID: %s | 🎯 Target ID: %s\n", MY_ID, TARGET_ID)
	fmt.Println("🌐 Using system recursive DNS, forced IPv4 to avoid AAAA delays.")
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
		queryStr := fmt.Sprintf("v1.sync.%s.%s", MY_ID, BASE_DOMAIN)

		ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
		txts, err := resolver4.LookupTXT(ctx, queryStr)
		cancel()

		if err != nil || len(txts) == 0 {
			time.Sleep(backoff)
			backoff = time.Duration(float64(backoff) * backoffStep)
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
			continue
		}

		txt := txts[0]
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
			handleAck2Metric(txt) // ✅ Peyk latency metric
		} else {
			handleIncomingChunk(txt)
		}

		time.Sleep(fastDelay)
	}
}

// ✅ Parse ACK2 and compute Peyk latency if it's for our outgoing message
func handleAck2Metric(txt string) {
	// format: ACK2-<sid>-<tot>
	parts := strings.Split(txt, "-")
	if len(parts) != 3 {
		return
	}

	sid := strings.ToLower(parts[1])
	tot, err := strconv.Atoi(parts[2])
	if err != nil || tot <= 0 {
		return
	}

	// Only measure latency for ACK2s that confirm messages WE sent.
	// (Those have sid == MY_ID)
	if sid != strings.ToLower(MY_ID) {
		return
	}

	key := fmt.Sprintf("%s:%d", sid, tot)

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

	senderID := strings.ToLower(parts[2])
	receiverID := strings.ToLower(parts[3])
	payload := strings.Join(parts[4:], "-")

	if receiverID != strings.ToLower(MY_ID) {
		return
	}
	if idx <= 0 || total <= 0 || idx > total || payload == "" {
		return
	}

	key := fmt.Sprintf("%s-%s-%d", senderID, receiverID, total)

	buffersMu.Lock()
	if _, ok := buffers[key]; !ok {
		buffers[key] = make(map[int]string)
	}
	buffers[key][idx] = payload
	got := len(buffers[key])
	buffersMu.Unlock()

	fmt.Printf("📦 [RX] Chunk %d/%d from %s (have %d/%d)\n", idx, total, senderID, got, total)

	if got == total {
		assembleAndDecrypt(key, total, senderID)
	}
}

func assembleAndDecrypt(key string, total int, senderID string) {
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
		go retryAck2Stable(senderID, total)
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
	go retryAck2Stable(senderID, total)
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
// Retry a few times (best-effort) because recursive DNS can drop.

func retryAck2Stable(senderID string, total int) {
	domain := fmt.Sprintf("ack2-%s-%d.%s", strings.ToLower(senderID), total, BASE_DOMAIN)

	for i := 0; i < 3; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
		_, _ = resolver4.LookupIP(ctx, "ip4", domain)
		cancel()
		time.Sleep(350 * time.Millisecond)
	}

	fmt.Printf("📨 ACK2 sent for %s/%d (stable)\n", senderID, total)
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

	sendChunksRecursive(encoded)
}

func sendChunksRecursive(data string) {
	chunkSize := 45
	total := (len(data) + chunkSize - 1) / chunkSize

	// ✅ record Peyk TX start time for latency metric
	// key is "<MY_ID>:<tot>", matching server ACK2 format: ACK2-<sid>-<tot>
	txKey := fmt.Sprintf("%s:%d", strings.ToLower(MY_ID), total)
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

		label := fmt.Sprintf("%d-%d-%s-%s-%s", i+1, total, MY_ID, TARGET_ID, data[start:end])
		host := label + "." + BASE_DOMAIN

		startTime := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
		_, err := resolver4.LookupIP(ctx, "ip4", host)
		cancel()
		rtt := time.Since(startTime)

		if err != nil {
			fmt.Printf("⚠️ [TX] Chunk %d/%d - SENT (ip4 err after %v)\n", i+1, total, rtt.Round(time.Millisecond))
			time.Sleep(slowPace)
		} else {
			fmt.Printf("📤 [TX] Chunk %d/%d - SENT (ip4 RTT: %v)\n", i+1, total, rtt.Round(time.Millisecond))
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
