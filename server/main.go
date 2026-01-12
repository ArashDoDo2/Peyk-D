package main

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base32"
	"errors"
	"fmt"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	encryptionKey = "my32characterslongsecretkey12345"
	baseDomain    = "p99.peyk-d.ir"
	sessionTTL    = 2 * time.Minute
	maxSessions   = 10000
	maxChunks     = 250
	workerCount   = 10   // تعداد کارگرهای ثابت برای پردازش
	maxQueueSize  = 1000 // ظرفیت صف انتظار پکت‌ها
)

type Session struct {
	Chunks    map[int]string
	Total     int
	CreatedAt time.Time
}

type PacketJob struct {
	Data []byte
	Addr *net.UDPAddr
}

var (
	sessions = make(map[string]*Session)
	mu       sync.RWMutex
	jobQueue = make(chan PacketJob, maxQueueSize)
)

func main() {
	addr, err := net.ResolveUDPAddr("udp", ":53")
	if err != nil {
		fmt.Printf("❌ Critical Error: %v\n", err)
		return
	}

	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		fmt.Printf("❌ Critical Error: %v\n", err)
		return
	}
	defer conn.Close()

	// ۱. راه‌اندازی Worker Pool
	for i := 0; i < workerCount; i++ {
		go worker(conn)
	}

	// ۲. مدیریت نشست‌های منقضی شده
	go sessionCleaner()

	fmt.Printf("🛡️ Peyk-D Pro Server (Worker Pool Mode) on %s\n", addr)

	buf := make([]byte, 1500)
	for {
		n, remoteAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}

		// ارسال به صف پردازش (Non-blocking send با استفاده از select)
		select {
		case jobQueue <- PacketJob{Data: append([]byte(nil), buf[:n]...), Addr: remoteAddr}:
		default:
			// صف پر است، پکت دیسکارد می‌شود (Backpressure)
		}
	}
}

func worker(conn *net.UDPConn) {
	for job := range jobQueue {
		// ارسال پاسخ سریع (با مدیریت خطا)
		sendDummyResponse(conn, job.Addr, job.Data)

		// پردازش محتوا
		if err := handlePacket(job.Data, job.Addr); err != nil {
			// در صورت نیاز لاگ شود
		}
	}
}

func handlePacket(data []byte, addr *net.UDPAddr) error {
	if len(data) < 13 {
		return errors.New("short packet")
	}

	fqdn := parseRFC1035(data[12:])
	if fqdn == "" || !strings.HasSuffix(fqdn, "."+baseDomain) {
		return errors.New("invalid domain")
	}

	label := strings.TrimSuffix(fqdn, "."+baseDomain)
	parts := strings.SplitN(label, "-", 4)
	if len(parts) < 4 {
		return errors.New("bad label format")
	}

	idx, _ := strconv.Atoi(parts[0])
	total, _ := strconv.Atoi(parts[1])
	msgId, payload := parts[2], parts[3]

	if idx < 1 || idx > total || total > maxChunks {
		return errors.New("range violation")
	}

	sessionKey := fmt.Sprintf("%s-%s", addr.IP.String(), msgId)

	// استفاده بهینه از RWMutex
	mu.RLock()
	s, exists := sessions[sessionKey]
	mu.RUnlock()

	if !exists {
		mu.Lock()
		if len(sessions) < maxSessions {
			sessions[sessionKey] = &Session{
				Chunks:    map[int]string{idx: payload},
				Total:     total,
				CreatedAt: time.Now(),
			}
		}
		mu.Unlock()
	} else {
		mu.Lock()
		s.Chunks[idx] = payload
		ready := len(s.Chunks) == s.Total
		var chunksCopy map[int]string
		if ready {
			chunksCopy = make(map[int]string, len(s.Chunks))
			for k, v := range s.Chunks {
				chunksCopy[k] = v
			}
			delete(sessions, sessionKey)
		}
		mu.Unlock()

		if ready {
			go processFullMessage(chunksCopy)
		}
	}
	return nil
}

func processFullMessage(chunks map[int]string) {
	indices := make([]int, 0, len(chunks))
	for k := range chunks {
		indices = append(indices, k)
	}
	sort.Ints(indices)

	var sb strings.Builder
	for _, i := range indices {
		sb.WriteString(chunks[i])
	}

	data := strings.ToUpper(sb.String())
	for len(data)%8 != 0 {
		data += "="
	}

	raw, err := base32.StdEncoding.DecodeString(data)
	if err != nil || len(raw) < 28 {
		return
	}

	nonce, tag, ciphertext := raw[:12], raw[12:28], raw[28:]
	block, _ := aes.NewCipher([]byte(encryptionKey))
	aesGCM, _ := cipher.NewGCM(block)

	plaintext, err := aesGCM.Open(nil, nonce, append(ciphertext, tag...), nil)
	if err != nil {
		return
	}

	// Sanitize output (جلوگیری از چاپ کاراکترهای کنترلی)
	sanitized := strings.Map(func(r rune) rune {
		if unicode.IsPrint(r) {
			return r
		}
		return -1
	}, string(plaintext))

	if len(sanitized) > 0 {
		fmt.Printf("[%s] 🔓 Decrypted: %s\n", time.Now().Format("15:04:05"), sanitized)
	}
}

func sendDummyResponse(conn *net.UDPConn, addr *net.UDPAddr, req []byte) {
	if len(req) < 4 {
		return
	}
	resp := make([]byte, len(req))
	copy(resp, req)
	resp[2], resp[3] = 0x81, 0x80
	_, _ = conn.WriteToUDP(resp, addr)
}

func parseRFC1035(qname []byte) string {
	var parts []string
	for i := 0; i < len(qname); {
		length := int(qname[i])
		if length == 0 {
			break
		}
		if length > 63 || i+1+length > len(qname) {
			break
		}
		i++
		parts = append(parts, string(qname[i:i+length]))
		i += length
	}
	return strings.Join(parts, ".")
}

func sessionCleaner() {
	ticker := time.NewTicker(30 * time.Second)
	for range ticker.C {
		mu.Lock()
		for key, s := range sessions {
			if time.Since(s.CreatedAt) > sessionTTL {
				delete(sessions, key)
			}
		}
		mu.Unlock()
	}
}
