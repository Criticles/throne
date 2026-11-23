// Package libbox — оверлей Xray для iOS.
//
// Почему оверлей, а не отдельный фреймворк: gomobile генерирует один фреймворк на пакет,
// а два Go-рантайма в одном процессе iOS не уживаются (проверено с Turnable). Поэтому Xray
// линкуется в тот же Libbox.xcframework, что и sing-box, и живёт рядом с ним.
//
// Задача Xray — протоколы, которых нет в sing-box: в первую очередь VLESS + XHTTP.
package libbox

import (
	"fmt"
	"strings"
	"sync"

	xcore "github.com/xtls/xray-core/core"
	// Регистрирует все inbound/outbound/transport Xray (vless, reality, xhttp, socks).
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	xrayMu       sync.Mutex
	xrayInstance *xcore.Instance
)

// LibboxXrayStart поднимает Xray с полным JSON-конфигом.
// Ожидается, что конфиг содержит socks-инбаунд на 127.0.0.1:7892 — через него идёт проверка.
func LibboxXrayStart(configJSON string) error {
	xrayMu.Lock()
	defer xrayMu.Unlock()

	if xrayInstance != nil {
		return fmt.Errorf("xray уже запущен")
	}
	raw := strings.TrimSpace(configJSON)
	if raw == "" {
		return fmt.Errorf("пустой конфиг Xray")
	}
	config, err := xcore.LoadConfig("json", strings.NewReader(raw))
	if err != nil {
		return fmt.Errorf("parse config: %w", err)
	}
	instance, err := xcore.New(config)
	if err != nil {
		return fmt.Errorf("new instance: %w", err)
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		return fmt.Errorf("start: %w", err)
	}
	xrayInstance = instance
	return nil
}

// LibboxXrayStop гасит Xray и освобождает socks-порт.
func LibboxXrayStop() error {
	xrayMu.Lock()
	defer xrayMu.Unlock()
	if xrayInstance == nil {
		return nil
	}
	err := xrayInstance.Close()
	xrayInstance = nil
	return err
}

// LibboxXrayIsRunning сообщает, поднят ли Xray (для интерфейса).
func LibboxXrayIsRunning() bool {
	xrayMu.Lock()
	defer xrayMu.Unlock()
	return xrayInstance != nil
}
