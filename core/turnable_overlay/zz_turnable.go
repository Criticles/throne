// Оверлей: биндинг клиента Turnable внутри пакета libbox.
//
// Почему так, а не отдельным фреймворком: gomobile-фреймворки нельзя линковать
// по два в один процесс — каждый тянет свой Go runtime, и приложение падает
// на старте. Поэтому второй биндинг живёт в том же пакете, что и ядро.
//
// Этот файл копируется в experimental/libbox клонированного форка при сборке
// (см. .github/workflows/ios.yml) и в дереве sing-box не хранится.
package libbox

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"

	"github.com/theairblow/turnable/pkg/common"
	"github.com/theairblow/turnable/pkg/config"
	"github.com/theairblow/turnable/pkg/engine"
	_ "github.com/theairblow/turnable/pkg/init"
)

// LibboxLogSink реализуется на стороне клиента (Swift/Kotlin).
type LibboxLogSink interface {
	WriteLog(message string)
}

var (
	turnableMu       sync.Mutex
	turnableClient   *engine.TurnableClient
	turnableListen   string
	turnableSinkMu   sync.Mutex
	turnableLogSink  LibboxLogSink
)

// TurnableSetup готовит транспорт: неинтерактивный режим (браузера для капчи на iOS нет).
func TurnableSetup(basePath string) error {
	config.Options.Interactive = false
	level := slog.LevelInfo
	common.SetLogLevel(int(level))
	_ = basePath
	return nil
}

// TurnableSetLogSink подписывает приёмник логов Turnable.
func TurnableSetLogSink(sink LibboxLogSink) {
	turnableSinkMu.Lock()
	turnableLogSink = sink
	turnableSinkMu.Unlock()
}

// TurnableIsRunning сообщает, поднят ли транспорт.
func TurnableIsRunning() bool {
	turnableMu.Lock()
	defer turnableMu.Unlock()
	return turnableClient != nil
}

// TurnableListenAddress возвращает адрес, на котором слушает транспорт.
func TurnableListenAddress() string {
	turnableMu.Lock()
	defer turnableMu.Unlock()
	return turnableListen
}

// TurnableStart поднимает клиент Turnable по JSON-конфигу из wireturn-профиля.
func TurnableStart(configJSON string, listenAddr string) error {
	turnableMu.Lock()
	defer turnableMu.Unlock()

	if turnableClient != nil {
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
	instance.SetLogger(slog.New(turnableSinkHandler{}))
	if err := instance.Start([]string{listenAddr}); err != nil {
		return fmt.Errorf("start: %w", err)
	}
	turnableClient = instance
	turnableListen = listenAddr
	return nil
}

// TurnableStop гасит транспорт и освобождает порт.
func TurnableStop() error {
	turnableMu.Lock()
	defer turnableMu.Unlock()
	if turnableClient == nil {
		return nil
	}
	err := turnableClient.Stop()
	turnableClient = nil
	turnableListen = ""
	return err
}

type turnableSinkHandler struct{}

func (turnableSinkHandler) Enabled(context.Context, slog.Level) bool { return true }

func (turnableSinkHandler) Handle(_ context.Context, record slog.Record) error {
	turnableSinkMu.Lock()
	target := turnableLogSink
	turnableSinkMu.Unlock()
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

func (turnableSinkHandler) WithAttrs([]slog.Attr) slog.Handler { return turnableSinkHandler{} }

func (turnableSinkHandler) WithGroup(string) slog.Handler { return turnableSinkHandler{} }
