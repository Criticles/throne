// Package turnablecore — gomobile-биндинг клиента Turnable для iOS.
//
// Turnable — это транспорт, а не VPN: клиент слушает локальный порт и гонит
// TCP/UDP через VK TURN/SFU. Для wireturn-профилей sing-box поднимает
// wireguard-endpoint на этот локальный порт (127.0.0.1:9000), а Turnable
// доставляет пакеты до WG-сервера. Капча в браузере на iOS пока не поддерживается,
// поэтому интерактивный режим выключен.
package turnablecore

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/theairblow/turnable/pkg/common"
	"github.com/theairblow/turnable/pkg/config"
	"github.com/theairblow/turnable/pkg/engine"
)

// LogSink реализуется на стороне Swift: строки лога уходят в UI.
type LogSink interface {
	WriteLog(message string)
}

var (
	mu       sync.Mutex
	client   *engine.TurnableClient
	listenAt string

	sinkMu sync.Mutex
	sink   LogSink
)

// Setup готовит окружение. basePath — каталог приложения (Application Support).
func Setup(basePath string) error {
	if basePath != "" {
		if err := os.MkdirAll(filepath.Join(basePath, "turnable"), 0o755); err != nil {
			return fmt.Errorf("create turnable dir: %w", err)
		}
	}
	// Браузера для капчи на iOS нет — только неинтерактивный режим.
	config.Options.Interactive = false
	common.SetLogLevel(int(slog.LevelInfo))
	return nil
}

// SetLogSink подписывает приёмник логов (можно передать nil, чтобы отписаться).
func SetLogSink(s LogSink) {
	sinkMu.Lock()
	sink = s
	sinkMu.Unlock()
}

// Version возвращает версию движка для UI.
func Version() string { return "turnable v0.8.5" }

// IsRunning сообщает, поднят ли клиент.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return client != nil
}

// Start поднимает клиента с JSON-конфигом Turnable (тот, что панель кладёт в wireturn).
// listenAddr — локальный адрес, куда будет смотреть sing-box (обычно 127.0.0.1:9000).
func Start(configJSON string, listenAddr string) error {
	mu.Lock()
	defer mu.Unlock()

	if client != nil {
		return fmt.Errorf("turnable уже запущен")
	}
	raw := strings.TrimSpace(configJSON)
	if raw == "" {
		return fmt.Errorf("пустой конфиг Turnable")
	}
	cfg, err := config.ParseClientConfig([]byte(raw))
	if err != nil {
		return fmt.Errorf("parse config: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return fmt.Errorf("validate config: %w", err)
	}
	if strings.TrimSpace(listenAddr) == "" {
		listenAddr = "127.0.0.1:9000"
	}

	instance := engine.NewTurnableClient(cfg)
	instance.SetLogger(slog.New(sinkHandler{}))
	if err := instance.Start([]string{listenAddr}); err != nil {
		return fmt.Errorf("start: %w", err)
	}
	client = instance
	listenAt = listenAddr
	return nil
}

// Stop гасит клиента и освобождает локальный порт.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if client == nil {
		return nil
	}
	err := client.Stop()
	client = nil
	listenAt = ""
	return err
}

// ListenAddress возвращает адрес, на котором слушает клиент (для лога и проверок).
func ListenAddress() string {
	mu.Lock()
	defer mu.Unlock()
	return listenAt
}

type sinkHandler struct{}

func (sinkHandler) Enabled(context.Context, slog.Level) bool { return true }

func (sinkHandler) Handle(_ context.Context, record slog.Record) error {
	sinkMu.Lock()
	target := sink
	sinkMu.Unlock()
	if target == nil {
		return nil
	}
	var line strings.Builder
	line.WriteString(record.Message)
	record.Attrs(func(attr slog.Attr) bool {
		line.WriteString(" ")
		line.WriteString(attr.Key)
		line.WriteString("=")
		line.WriteString(attr.Value.String())
		return true
	})
	target.WriteLog(line.String())
	return nil
}

func (sinkHandler) WithAttrs([]slog.Attr) slog.Handler { return sinkHandler{} }

func (sinkHandler) WithGroup(string) slog.Handler { return sinkHandler{} }
