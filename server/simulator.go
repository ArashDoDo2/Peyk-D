package main

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"time"
)

const (
	SERVER_ADDR = "127.0.0.1:53"
	BASE_DOMAIN = "p99.peyk-d.ir"
	PASSPHRASE  = "my-fixed-passphrase-change-me"

	MY_ID     = "simul" // simulator id (receiver in polling)
	TARGET_ID = "a3akc" // mobile id
)

var buffers = make(map[string]map[int]string)

func main() {
	fmt.Println("🚀 Peyk Simulator Pro Started...")
	fmt.Printf("🆔 My ID: %s | 🎯 Target ID: %s\n", MY_ID, TARGET_ID)
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

// ───────────────────────── POLLING ─────────────────────────

func startPolling() {
	for {
		hasMore := true
		for hasMore {
			queryStr := fmt.Sprintf("v1.sync.%s.%s", MY_ID, BASE_DOMAIN)

			// IMPORTANT: polling must be TXT query (QTYPE=16)
			packet := buildDnsQuery(queryStr, 16)

			conn, err := net.Dial("udp", SERVER_ADDR)
			if err != nil {
				hasMore = false
				continue
			}

			_, _ = conn.Write(packet)

			buffer := make([]byte, 1024)
			_ = conn.SetReadDeadline(time.Now().Add(1200 * time.Millisecond))
			n, err := conn.Read(buffer)
			_ = conn.Close()

			if err != nil || n <= 0 {
				hasMore = false
				continue
			}

			txt := extractTxt(buffer[:n])
			if txt == "" || txt == "NOP" {
				hasMore = false
				continue
			}

			// ACK2 for sender might appear as TXT (if you are also sender)
			if strings.HasPrefix(txt, "ACK2-") {
				fmt.Println("✅ [ACK2 RECEIVED]", txt)
				hasMore = true
				continue
			}

			handleIncomingChunk(txt)
			hasMore = true
			time.Sleep(200 * time.Millisecond)
		}

		time.Sleep(2 * time.Second)
	}
}

// ───────────────────────── RX ─────────────────────────

func handleIncomingChunk(txt string) {
	parts := strings.Split(txt, "-")
	if len(parts) < 5 {
		return
	}

	var idx, total int
	fmt.Sscanf(parts[0], "%d", &idx)
	fmt.Sscanf(parts[1], "%d", &total)

	senderID := strings.ToLower(parts[2])
	receiverID := strings.ToLower(parts[3])
	payload := strings.Join(parts[4:], "-")

	if receiverID != strings.ToLower(MY_ID) {
		return
	}

	key := fmt.Sprintf("%s-%s-%d", senderID, receiverID, total)
	if _, ok := buffers[key]; !ok {
		buffers[key] = make(map[int]string)
	}
	buffers[key][idx] = payload

	fmt.Printf("📦 [RX] Chunk %d/%d from %s\n", idx, total, senderID)

	if len(buffers[key]) == total {
		assembleAndDecrypt(key, total, senderID)
	}
}

func assembleAndDecrypt(key string, total int, senderID string) {
	var sb strings.Builder
	for i := 1; i <= total; i++ {
		sb.WriteString(buffers[key][i])
	}
	fullB32 := sb.String()
	delete(buffers, key)

	raw, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(strings.ToUpper(fullB32))
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

	// IMPORTANT: send ACK2 back to server so sender gets ✓✓
	sendAck2(senderID, total)
}

func sendAck2(senderID string, total int) {
	// ack2-<sid>-<tot>.<base>  (sid is original sender)
	domain := fmt.Sprintf("ack2-%s-%d.%s", strings.ToLower(senderID), total, BASE_DOMAIN)
	q := buildDnsQuery(domain, 1) // ACK2 is A-query

	conn, err := net.Dial("udp", SERVER_ADDR)
	if err != nil {
		return
	}
	defer conn.Close()

	_, _ = conn.Write(q)
	// optional: read server ACK (not required)
	_ = conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	tmp := make([]byte, 512)
	_, _ = conn.Read(tmp)

	fmt.Printf("✅ Sent ACK2 for %s/%d\n", senderID, total)
}

// ───────────────────────── TX (sending) ─────────────────────────

func sendManualMessage(msg string) {
	hash := sha256.Sum256([]byte(PASSPHRASE))
	key := hash[:]

	block, _ := aes.NewCipher(key)
	aesgcm, _ := cipher.NewGCM(block)

	nonce := make([]byte, 12)
	_, _ = io.ReadFull(rand.Reader, nonce)

	encrypted := aesgcm.Seal(nil, nonce, []byte(msg), nil)
	fullData := append(nonce, encrypted...) // nonce + ciphertext+tag

	encoded := strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(fullData))
	sendChunks(encoded)
}

func sendChunks(data string) {
	chunkSize := 45
	total := (len(data) + chunkSize - 1) / chunkSize

	for i := 0; i < total; i++ {
		start := i * chunkSize
		end := start + chunkSize
		if end > len(data) {
			end = len(data)
		}

		label := fmt.Sprintf("%d-%d-%s-%s-%s", i+1, total, MY_ID, TARGET_ID, data[start:end])
		query := buildDnsQuery(label+"."+BASE_DOMAIN, 1) // send chunks as A query

		conn, err := net.Dial("udp", SERVER_ADDR)
		if err != nil {
			fmt.Println("❌ Network Error:", err)
			return
		}

		_, _ = conn.Write(query)

		// optional: read server ACK (✓)
		ackBuffer := make([]byte, 512)
		_ = conn.SetReadDeadline(time.Now().Add(1200 * time.Millisecond))
		_, err = conn.Read(ackBuffer)
		_ = conn.Close()

		if err != nil {
			fmt.Printf("⚠️ [TX] Chunk %d/%d - No Server ACK\n", i+1, total)
		} else {
			fmt.Printf("📤 [TX] Chunk %d/%d - Server ACK ✓\n", i+1, total)
		}

		time.Sleep(120 * time.Millisecond)
	}
	fmt.Println("✅ Message Transmission Finished.")
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
	ciphertextWithTag := data[12:]

	plaintext, err := aesgcm.Open(nil, nonce, ciphertextWithTag, nil)
	return string(plaintext), err
}

// ───────────────────────── DNS: build query with qtype ─────────────────────────

func buildDnsQuery(domain string, qtype uint16) []byte {
	// Header: ID(2), Flags(2), QDCOUNT(2), AN/NS/AR(2 each)
	packet := []byte{
		0xAB, 0xCD,
		0x01, 0x00,
		0x00, 0x01,
		0x00, 0x00,
		0x00, 0x00,
		0x00, 0x00,
	}

	for _, label := range strings.Split(domain, ".") {
		if label == "" {
			continue
		}
		packet = append(packet, byte(len(label)))
		packet = append(packet, []byte(label)...)
	}
	packet = append(packet, 0x00)

	qt := make([]byte, 2)
	binary.BigEndian.PutUint16(qt, qtype)
	packet = append(packet, qt...)

	// QCLASS IN
	packet = append(packet, 0x00, 0x01)
	return packet
}

// ───────────────────────── DNS: extract TXT properly ─────────────────────────

func extractTxt(msg []byte) string {
	// minimal DNS TXT extractor (single answer is enough)
	if len(msg) < 12 {
		return ""
	}

	i := 12

	// skip QNAME
	for i < len(msg) {
		if msg[i] == 0x00 {
			i++
			break
		}
		l := int(msg[i])
		if l == 0 || i+1+l > len(msg) {
			return ""
		}
		i += 1 + l
	}

	// skip QTYPE/QCLASS
	if i+4 > len(msg) {
		return ""
	}
	i += 4

	// parse answers
	for i+10 <= len(msg) {
		// NAME
		if (msg[i] & 0xC0) == 0xC0 {
			i += 2
		} else {
			for i < len(msg) && msg[i] != 0x00 {
				i += 1 + int(msg[i])
			}
			i++
		}
		if i+10 > len(msg) {
			return ""
		}

		typ := binary.BigEndian.Uint16(msg[i : i+2])
		i += 2
		_ = binary.BigEndian.Uint16(msg[i : i+2]) // class
		i += 2
		i += 4 // ttl

		rdLen := int(binary.BigEndian.Uint16(msg[i : i+2]))
		i += 2
		if i+rdLen > len(msg) {
			return ""
		}

		if typ == 16 && rdLen >= 1 { // TXT
			end := i + rdLen
			j := i
			var out strings.Builder
			for j < end {
				l := int(msg[j])
				j++
				if j+l > end {
					break
				}
				out.Write(msg[j : j+l])
				j += l
			}
			return strings.TrimSpace(out.String())
		}

		i += rdLen
	}
	return ""
}
