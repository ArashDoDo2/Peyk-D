package main

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base32"
	"encoding/base64"
	"fmt"
	"net"
	"strings"
)

var (
	key = []byte("my32characterslongsecretkey12345") // ۳۲ کاراکتر (باید با کلاینت یکی باشد)
	iv  = []byte("1212312312312312")                 // ۱۶ کاراکتر
)

var messageBuffer = make(map[string]string)

func main() {
	addr, _ := net.ResolveUDPAddr("udp", ":53")
	conn, _ := net.ListenUDP("udp", addr)
	defer conn.Close()

	fmt.Println("🚀 Peyk-D Secure Server (Phase 3: AES) Listening...")

	buf := make([]byte, 1024)
	for {
		n, _, _ := conn.ReadFromUDP(buf)
		parts := strings.Split(string(buf[:n]), "-")
		if len(parts) < 3 {
			continue
		}

		index, total := parts[0], parts[1]
		payload := strings.Split(parts[2], ".")[0]
		messageBuffer[index] = payload

		if index == total {
			// ۱. بازسازی Base32
			fullB32 := strings.ToUpper(strings.Join(assemble(messageBuffer, total), ""))
			for len(fullB32)%8 != 0 {
				fullB32 += "="
			}
			encryptedBase64, _ := base32.StdEncoding.DecodeString(fullB32)

			// ۲. رمزگشایی AES
			block, _ := aes.NewCipher(key)
			mode := cipher.NewCBCDecrypter(block, iv)

			ciphertext, _ := base64.StdEncoding.DecodeString(string(encryptedBase64))
			decrypted := make([]byte, len(ciphertext))
			mode.CryptBlocks(decrypted, ciphertext)

			// ۳. حذف Padding (در AES بلاک‌ها باید ۱۶ بایتی باشند)
			finalMsg := strings.TrimSpace(string(decrypted))
			fmt.Printf("\n🔓 Decrypted Secure Message: %s\n", finalMsg)
			messageBuffer = make(map[string]string)
		}
	}
}

func assemble(m map[string]string, total string) []string {
	var res []string
	for i := 1; i <= 20; i++ { // فرض برای تست
		if val, ok := m[fmt.Sprint(i)]; ok {
			res = append(res, val)
		}
	}
	return res
}
