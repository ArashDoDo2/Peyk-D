package main

import (
	"fmt"
	"net"
)

func main() {
	// شنود روی پورت 53 (حتما VS Code را به صورت Admin باز کنید)
	addr, err := net.ResolveUDPAddr("udp", ":53")
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}

	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		fmt.Printf("❌ خطا در اجرای سرور: %v\n", err)
		fmt.Println("💡 راه حل: VS Code را ببندید و روی آیکون آن راست‌کلیک کرده و Run as Administrator را بزنید.")
		return
	}
	defer conn.Close()

	fmt.Println("🚀 Peyk-D Server is listening on Port 53...")
	fmt.Println("⏳ Waiting for messages from Emulator...")

	buf := make([]byte, 1024)
	for {
		n, remoteAddr, _ := conn.ReadFromUDP(buf)
		fmt.Printf("📩 پیام جدید از %s: %s\n", remoteAddr, string(buf[:n]))
	}
}