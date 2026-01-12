package main

import (
	"encoding/base32"
	"fmt"
	"net"
	"strings"
)

func main() {
	addr, _ := net.ResolveUDPAddr("udp", ":53")
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	defer conn.Close()

	fmt.Println("🚀 Peyk-D Server (Phase 1) listening on Port 53...")

	buf := make([]byte, 1024)
	for {
		n, remoteAddr, _ := conn.ReadFromUDP(buf)
		rawPayload := string(buf[:n])

		// ۱. جدا کردن بخش کدگذاری شده (قبل از اولین دات)
		parts := strings.Split(rawPayload, ".")
		encodedData := strings.ToUpper(parts[0]) // Base32 باید حروف بزرگ باشد

		// ۲. اضافه کردن Padding (اگر طول رشته مضربی از 8 نباشد، Base32 استاندارد نیاز به = دارد)
		for len(encodedData)%8 != 0 {
			encodedData += "="
		}

		// ۳. رمزگشایی (Decode)
		decodedBytes, err := base32.StdEncoding.DecodeString(encodedData)
		if err != nil {
			fmt.Printf("📩 Raw (Error Decoding): %s\n", rawPayload)
			continue
		}

		fmt.Printf("📩 از %s | متن اصلی: %s\n", remoteAddr, string(decodedBytes))
	}
}
