package main

import (
	"encoding/base32"
	"fmt"
	"net"
	"strings"
)

// محلی برای ذخیره تکه‌های پیام (در نسخه نهایی از دیتابیس یا Map استفاده می‌کنیم)
var messageBuffer = make(map[string]string)

func main() {
	addr, _ := net.ResolveUDPAddr("udp", ":53")
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	defer conn.Close()

	fmt.Println("🚀 Peyk-D Server (Phase 2: Chunking) Listening...")

	buf := make([]byte, 1024)
	for {
		n, remoteAddr, _ := conn.ReadFromUDP(buf)
		raw := string(buf[:n])

		// جدا کردن اجزا: [index]-[total]-[payload]
		parts := strings.Split(raw, "-")
		if len(parts) < 3 {
			continue
		}

		index := parts[0]
		total := parts[1]
		payload := strings.Split(parts[2], ".")[0]

		fmt.Printf("📦 Received chunk %s/%s from %s\n", index, total, remoteAddr)

		// چسباندن موقت (در فاز ساده فعلی)
		messageBuffer[index] = payload

		// اگر تمام تکه‌ها رسیدند (ساده‌سازی شده برای تست)
		if index == total {
			fullEncoded := ""
			for i := 1; i <= len(messageBuffer); i++ {
				fullEncoded += messageBuffer[fmt.Sprint(i)]
			}

			// بازسازی برای Decode
			fullEncoded = strings.ToUpper(fullEncoded)
			for len(fullEncoded)%8 != 0 {
				fullEncoded += "="
			}

			decoded, _ := base32.StdEncoding.DecodeString(fullEncoded)
			fmt.Printf("\n✨ COMPLETE MESSAGE: %s\n\n", string(decoded))

			// خالی کردن بافر برای پیام بعدی
			messageBuffer = make(map[string]string)
		}
	}
}
