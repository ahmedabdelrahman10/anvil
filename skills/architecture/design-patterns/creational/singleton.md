---
name: singleton-pattern
description: Singleton pattern and its alternatives
category: architecture/design-patterns/creational
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Singleton Pattern

## Overview

The Singleton pattern ensures a class has only one instance and provides
a global point of access to it. **Use sparingly** - often considered an
anti-pattern in modern development. In Go a global singleton is usually a
smell: prefer constructor injection and pass one instance around.

## Classic Singleton

```go
// Basic singleton via sync.Once (not recommended — prefer injection).
package logging

//nolint:gochecknoglobals // deliberate process-wide singleton, guarded by sync.Once
var (
	loggerInstance *Logger
	loggerOnce     sync.Once
)

type Logger struct{}

// GetLogger returns the process-wide Logger, creating it exactly once.
func GetLogger() *Logger {
	loggerOnce.Do(func() {
		loggerInstance = &Logger{}
	})
	return loggerInstance
}

func (l *Logger) Log(message string) {
	fmt.Printf("[%s] %s\n", time.Now().UTC().Format(time.RFC3339), message)
}

// Usage
GetLogger().Log("Application started")
```

## Problems with Singleton

```go
// ❌ Global state — hard to test
type UserService struct{}

func (s *UserService) User(id string) (User, error) {
	// Direct dependency on the singleton — cannot substitute a fake in tests.
	GetLogger().Log(fmt.Sprintf("Fetching user %s", id))
	// ...
	return User{}, nil
}

// ❌ Hidden dependencies
type OrderService struct{}

func (s *OrderService) ProcessOrder(order Order) error {
	// What does this method depend on? You cannot tell from the struct or its
	// constructor — the dependencies are reached through package-level singletons.
	GetLogger().Log("Processing order")
	if err := GetDatabase().Save(order); err != nil {
		return fmt.Errorf("save order: %w", err)
	}
	GetEmailService().Send("Order processed")
	return nil
}

// ❌ Data races when the singleton's state is mutated concurrently
// ❌ Difficult to reset state between tests
// ❌ Violates the Single Responsibility Principle
```

## Better Alternative: Dependency Injection

```go
// ✅ Logger as an injectable dependency (small consumer-side interface)
type Logger interface {
	Log(message string)
	Error(message string, err error)
}

type ConsoleLogger struct{}

func NewConsoleLogger() *ConsoleLogger {
	return &ConsoleLogger{}
}

func (l *ConsoleLogger) Log(message string) {
	fmt.Printf("[%s] %s\n", time.Now().UTC().Format(time.RFC3339), message)
}

func (l *ConsoleLogger) Error(message string, err error) {
	fmt.Printf("[%s] ERROR: %s: %v\n", time.Now().UTC().Format(time.RFC3339), message, err)
}

// Service receives its logger through the constructor.
type UserService struct {
	logger Logger
}

func NewUserService(logger Logger) *UserService {
	return &UserService{logger: logger}
}

func (s *UserService) User(id string) (User, error) {
	s.logger.Log(fmt.Sprintf("Fetching user %s", id))
	// ...
	return User{}, nil
}

// Easy to test with a fake logger.
type fakeLogger struct {
	messages []string
}

func (f *fakeLogger) Log(message string)              { f.messages = append(f.messages, message) }
func (f *fakeLogger) Error(message string, err error) {}

func TestUserService(t *testing.T) {
	logger := &fakeLogger{}
	service := NewUserService(logger)
	// ... assert against logger.messages
	_ = service
}
```

## When Singleton Is Acceptable

### 1. Configuration Management

```go
// Application configuration — read-only after initialization.
//
//nolint:gochecknoglobals // read-only config loaded once at startup
var (
	configInstance *Config
	configOnce     sync.Once
)

// Config is immutable after load.
type Config struct {
	DatabaseURL string
	APIKey      string
	Environment string
}

// GetConfig loads configuration from the environment exactly once.
func GetConfig() *Config {
	configOnce.Do(func() {
		env := os.Getenv("APP_ENV")
		if env == "" {
			env = "development"
		}
		configInstance = &Config{
			DatabaseURL: os.Getenv("DATABASE_URL"),
			APIKey:      os.Getenv("API_KEY"),
			Environment: env,
		}
	})
	return configInstance
}
```

### 2. Connection Pools

```go
// Database connection pool — expensive to create. Note *sql.DB is itself a
// pool and safe for concurrent use; open it once.
//
//nolint:gochecknoglobals // one shared connection pool for the process
var (
	dbPool *sql.DB
	dbOnce sync.Once
	dbErr  error
)

// GetDB returns the shared *sql.DB pool, opening it once. Prefer passing the
// *sql.DB in via a constructor wherever you can.
func GetDB() (*sql.DB, error) {
	dbOnce.Do(func() {
		db, err := sql.Open("pgx", os.Getenv("DATABASE_URL"))
		if err != nil {
			dbErr = fmt.Errorf("open database: %w", err)
			return
		}
		db.SetMaxOpenConns(20)
		db.SetConnMaxIdleTime(30 * time.Second)
		dbPool = db
	})
	if dbErr != nil {
		return nil, dbErr
	}
	return dbPool, nil
}
```

### 3. Hardware Resource Access

```go
// Printer spooler — only one worker may manage the printer. A single
// goroutine consuming a channel serializes access.
//
//nolint:gochecknoglobals // a single spooler owns the one physical printer
var (
	spoolerInstance *PrinterSpooler
	spoolerOnce     sync.Once
)

type PrinterSpooler struct {
	jobs chan PrintJob
}

// GetPrinterSpooler returns the process-wide spooler, starting its worker once.
func GetPrinterSpooler() *PrinterSpooler {
	spoolerOnce.Do(func() {
		s := &PrinterSpooler{jobs: make(chan PrintJob, 100)}
		go s.run()
		spoolerInstance = s
	})
	return spoolerInstance
}

// AddJob enqueues a job for printing.
func (s *PrinterSpooler) AddJob(job PrintJob) {
	s.jobs <- job
}

func (s *PrinterSpooler) run() {
	for job := range s.jobs {
		s.print(job)
	}
}

func (s *PrinterSpooler) print(job PrintJob) {
	// Send to printer.
}
```

## Lazy Initialization with Module Pattern

```go
// Go's closest analogue to a module-scoped singleton is a package-level
// accessor backed by sync.OnceValue (Go 1.21+), which lazily builds the
// value on first use.
//
//nolint:gochecknoglobals // lazy package-level logger, initialized once
var defaultLogger = sync.OnceValue(func() *LevelLogger {
	return &LevelLogger{level: LevelInfo}
})

type LogLevel int

const (
	LevelDebug LogLevel = iota
	LevelInfo
	LevelWarn
	LevelError
)

type LevelLogger struct {
	level LogLevel
}

func (l *LevelLogger) Log(message string) {
	if l.shouldLog(LevelInfo) {
		fmt.Printf("[INFO] %s\n", message)
	}
}

func (l *LevelLogger) Error(message string, err error) {
	if l.shouldLog(LevelError) {
		fmt.Printf("[ERROR] %s: %v\n", message, err)
	}
}

func (l *LevelLogger) shouldLog(level LogLevel) bool {
	return level >= l.level
}

// Usage — same instance everywhere.
defaultLogger().Log("Application started")
```

## Resettable Singleton for Testing

```go
// A resettable singleton trades a little safety for test isolation.
//
//nolint:gochecknoglobals // resettable cache singleton for illustration
var (
	cacheInstance *CacheManager
	cacheMu       sync.Mutex
)

type CacheManager struct {
	mu    sync.RWMutex
	cache map[string]any
}

// GetCacheManager returns the shared cache, creating it on first use.
func GetCacheManager() *CacheManager {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	if cacheInstance == nil {
		cacheInstance = &CacheManager{cache: make(map[string]any)}
	}
	return cacheInstance
}

// ResetCacheManager clears the singleton so each test starts clean.
func ResetCacheManager() {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	cacheInstance = nil
}

func (c *CacheManager) Get(key string) (any, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	value, ok := c.cache[key]
	return value, ok
}

func (c *CacheManager) Set(key string, value any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.cache[key] = value
}

func (c *CacheManager) Clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	clear(c.cache)
}

// In tests
func TestSomething(t *testing.T) {
	ResetCacheManager()
	// ... each test starts with a fresh cache
}
```

## Singleton with DI Container

```go
// In Go, "singleton scope" usually just means: construct once in main and
// pass the same value everywhere via constructors.
type EmailService struct {
	smtp      SMTPClient
	templates TemplateEngine
}

func NewEmailService(smtp SMTPClient, templates TemplateEngine) *EmailService {
	return &EmailService{smtp: smtp, templates: templates}
}

func (s *EmailService) Send(ctx context.Context, to, template string, data any) error {
	html, err := s.templates.Render(template, data)
	if err != nil {
		return fmt.Errorf("render template %q: %w", template, err)
	}
	if err := s.smtp.Send(ctx, to, html); err != nil {
		return fmt.Errorf("send email: %w", err)
	}
	return nil
}

// main.go — one instance, wired once and shared.
func main() {
	smtp := newSMTPClient()
	templates := newTemplateEngine()
	emailService := NewEmailService(smtp, templates)
	// pass emailService to whatever needs it
	_ = emailService
}
```

```go
// A runtime DI container (e.g. samber/do) can manage the single instance for
// you — each provider is resolved once and cached, giving a testable
// singleton. For compile-time wiring, use google/wire instead.
import "github.com/samber/do"

func buildInjector() *do.Injector {
	injector := do.New()
	do.Provide(injector, func(i *do.Injector) (SMTPClient, error) {
		return newSMTPClient(), nil
	})
	do.Provide(injector, func(i *do.Injector) (TemplateEngine, error) {
		return newTemplateEngine(), nil
	})
	do.Provide(injector, func(i *do.Injector) (*EmailService, error) {
		return NewEmailService(
			do.MustInvoke[SMTPClient](i),
			do.MustInvoke[TemplateEngine](i),
		), nil
	})
	return injector
}

// Single instance, but injectable and testable.
injector := buildInjector()
emailService := do.MustInvoke[*EmailService](injector)
```

## Summary

| Approach | When to Use |
|----------|------------|
| Avoid Singleton | Default choice - use DI instead |
| Singleton | Truly global state (config, hardware access) |
| Package-Level Value | Simple process-wide services |
| DI Singleton Scope | Need single instance with testability |

### Singleton Checklist

Before using Singleton, ask:
- [ ] Is there truly only one instance needed system-wide?
- [ ] Would DI achieve the same result with better testability?
- [ ] Is the singleton stateless or immutable?
- [ ] Can I easily reset it for testing?
- [ ] Am I hiding dependencies?
