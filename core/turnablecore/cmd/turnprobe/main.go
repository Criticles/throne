// Команда turnprobe — проверка связки WireTurn без iPhone.
//
// Поднимает клиент Turnable на локальном порту (по умолчанию 127.0.0.1:9000),
// чтобы рядом можно было запустить sing-box с wireguard-endpoint на этот порт.
// Запуск: turnprobe <путь к kernelConfig.config.json> [listen]
package main

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/criticles/throne/turnablecore"
)

type printer struct{}

func (printer) WriteLog(message string) { fmt.Println("[turnable]", message) }

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: turnprobe <config.json> [listen]")
		os.Exit(2)
	}
	listen := "127.0.0.1:9000"
	if len(os.Args) > 2 {
		listen = os.Args[2]
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Println("read config:", err)
		os.Exit(1)
	}
	if err := turnablecore.Setup("."); err != nil {
		fmt.Println("setup:", err)
		os.Exit(1)
	}
	turnablecore.SetLogSink(printer{})

	if err := turnablecore.Start(string(raw), listen); err != nil {
		fmt.Println("start:", err)
		os.Exit(1)
	}
	fmt.Println("turnable слушает", turnablecore.ListenAddress())

	// Держим клиент поднятым, чтобы рядом можно было прогнать sing-box.
	seconds := 600
	if raw := os.Getenv("TURNPROBE_SECONDS"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			seconds = parsed
		}
	}
	time.Sleep(time.Duration(seconds) * time.Second)
	if err := turnablecore.Stop(); err != nil {
		fmt.Println("stop:", err)
	}
	fmt.Println("остановлено")
}
