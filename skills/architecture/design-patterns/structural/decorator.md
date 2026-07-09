---
name: decorator-pattern
description: Decorator pattern for adding behavior dynamically
category: architecture/design-patterns/structural
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Decorator Pattern

## Overview

The Decorator pattern attaches additional responsibilities to an object
dynamically. Decorators provide a flexible alternative to subclassing
for extending functionality.

## Problem

```go
// A new type for every combination.
type Coffee struct{}

func (Coffee) Cost() float64 { return 5.0 }

type CoffeeWithMilk struct{}

func (CoffeeWithMilk) Cost() float64 { return 6.0 }

type CoffeeWithSugar struct{}

func (CoffeeWithSugar) Cost() float64 { return 5.5 }

type CoffeeWithMilkAndSugar struct{}

func (CoffeeWithMilkAndSugar) Cost() float64 { return 6.5 }

type CoffeeWithMilkAndWhip struct{}

func (CoffeeWithMilkAndWhip) Cost() float64 { return 7.0 }

// ... one type per combination.
// What about Milk + Sugar + Whip + Chocolate + ...? Type explosion!
```

## Solution: Decorator

```go
// Beverage is the component interface.
type Beverage interface {
	Description() string
	Cost() float64
}

// Espresso is a concrete component.
type Espresso struct{}

func (Espresso) Description() string { return "Espresso" }
func (Espresso) Cost() float64       { return 2.00 }

// HouseBlend is another concrete component.
type HouseBlend struct{}

func (HouseBlend) Description() string { return "House Blend Coffee" }
func (HouseBlend) Cost() float64       { return 1.50 }

// Each decorator holds the same interface and adds behavior.
type Milk struct {
	Beverage Beverage
}

func (m Milk) Description() string { return m.Beverage.Description() + ", Milk" }
func (m Milk) Cost() float64       { return m.Beverage.Cost() + 0.50 }

type Mocha struct {
	Beverage Beverage
}

func (m Mocha) Description() string { return m.Beverage.Description() + ", Mocha" }
func (m Mocha) Cost() float64       { return m.Beverage.Cost() + 0.75 }

type Whip struct {
	Beverage Beverage
}

func (w Whip) Description() string { return w.Beverage.Description() + ", Whip" }
func (w Whip) Cost() float64       { return w.Beverage.Cost() + 0.30 }

// Usage — compose any combination.
func main() {
	var beverage Beverage = Espresso{}
	beverage = Milk{Beverage: beverage}
	beverage = Mocha{Beverage: beverage}
	beverage = Whip{Beverage: beverage}

	fmt.Println(beverage.Description()) // "Espresso, Milk, Mocha, Whip"
	fmt.Println(beverage.Cost())        // 3.55
}
```

## Real-World Examples

### HTTP Client with Decorators

```go
package httpx

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"time"
)

// HTTPClient is the component interface.
type HTTPClient interface {
	Do(ctx context.Context, req Request) (Response, error)
}

type Request struct {
	Method  string
	URL     string
	Headers map[string]string
	Body    []byte
}

type Response struct {
	Data       []byte
	StatusCode int
	Cached     bool
}

// BaseHTTPClient is the concrete implementation.
type BaseHTTPClient struct {
	client *http.Client
}

func NewBaseHTTPClient(client *http.Client) *BaseHTTPClient {
	return &BaseHTTPClient{client: client}
}

func (c *BaseHTTPClient) Do(ctx context.Context, req Request) (Response, error) {
	httpReq, err := http.NewRequestWithContext(ctx, req.Method, req.URL, bytes.NewReader(req.Body))
	if err != nil {
		return Response{}, fmt.Errorf("build request: %w", err)
	}
	for k, v := range req.Headers {
		httpReq.Header.Set(k, v)
	}

	resp, err := c.client.Do(httpReq)
	if err != nil {
		return Response{}, fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return Response{}, fmt.Errorf("read body: %w", err)
	}
	return Response{Data: data, StatusCode: resp.StatusCode}, nil
}

// LoggingHTTPClient decorates any HTTPClient with structured logging.
type LoggingHTTPClient struct {
	next   HTTPClient
	logger *slog.Logger
}

func NewLoggingHTTPClient(next HTTPClient, logger *slog.Logger) *LoggingHTTPClient {
	return &LoggingHTTPClient{next: next, logger: logger}
}

func (c *LoggingHTTPClient) Do(ctx context.Context, req Request) (Response, error) {
	start := time.Now()
	resp, err := c.next.Do(ctx, req)
	if err != nil {
		c.logger.Error("http request failed", "method", req.Method, "url", req.URL, "err", err)
		return Response{}, err
	}
	c.logger.Info("http request",
		"method", req.Method, "url", req.URL, "status", resp.StatusCode, "duration", time.Since(start))
	return resp, nil
}

// RetryHTTPClient decorates with bounded retries.
type RetryHTTPClient struct {
	next       HTTPClient
	maxRetries int
	delay      time.Duration
}

func NewRetryHTTPClient(next HTTPClient, maxRetries int, delay time.Duration) *RetryHTTPClient {
	return &RetryHTTPClient{next: next, maxRetries: maxRetries, delay: delay}
}

func (c *RetryHTTPClient) Do(ctx context.Context, req Request) (Response, error) {
	var lastErr error
	for attempt := 1; attempt <= c.maxRetries; attempt++ {
		resp, err := c.next.Do(ctx, req)
		if err == nil {
			return resp, nil
		}
		lastErr = err
		if attempt < c.maxRetries {
			select {
			case <-ctx.Done():
				return Response{}, ctx.Err()
			case <-time.After(c.delay * time.Duration(attempt)):
			}
		}
	}
	return Response{}, fmt.Errorf("after %d attempts: %w", c.maxRetries, lastErr)
}

// AuthHTTPClient decorates with a bearer token.
type AuthHTTPClient struct {
	next  HTTPClient
	token func(ctx context.Context) (string, error)
}

func NewAuthHTTPClient(next HTTPClient, token func(ctx context.Context) (string, error)) *AuthHTTPClient {
	return &AuthHTTPClient{next: next, token: token}
}

func (c *AuthHTTPClient) Do(ctx context.Context, req Request) (Response, error) {
	token, err := c.token(ctx)
	if err != nil {
		return Response{}, fmt.Errorf("fetch token: %w", err)
	}
	if req.Headers == nil {
		req.Headers = make(map[string]string)
	}
	req.Headers["Authorization"] = "Bearer " + token
	return c.next.Do(ctx, req)
}

// CachingHTTPClient decorates with a TTL cache for GET requests.
type CachingHTTPClient struct {
	next HTTPClient
	ttl  time.Duration

	mu    sync.Mutex
	cache map[string]cacheEntry
}

type cacheEntry struct {
	data    []byte
	expires time.Time
}

func NewCachingHTTPClient(next HTTPClient, ttl time.Duration) *CachingHTTPClient {
	return &CachingHTTPClient{next: next, ttl: ttl, cache: make(map[string]cacheEntry)}
}

func (c *CachingHTTPClient) Do(ctx context.Context, req Request) (Response, error) {
	// Only cache GET requests.
	if req.Method != http.MethodGet {
		return c.next.Do(ctx, req)
	}

	key := req.Method + ":" + req.URL

	c.mu.Lock()
	entry, ok := c.cache[key]
	c.mu.Unlock()
	if ok && entry.expires.After(time.Now()) {
		return Response{Data: entry.data, StatusCode: http.StatusOK, Cached: true}, nil
	}

	resp, err := c.next.Do(ctx, req)
	if err != nil {
		return Response{}, err
	}

	c.mu.Lock()
	c.cache[key] = cacheEntry{data: resp.Data, expires: time.Now().Add(c.ttl)}
	c.mu.Unlock()
	return resp, nil
}

// Usage — compose decorators.
func build(logger *slog.Logger, token func(context.Context) (string, error)) HTTPClient {
	var client HTTPClient = NewBaseHTTPClient(http.DefaultClient)
	client = NewCachingHTTPClient(client, 30*time.Second)
	client = NewRetryHTTPClient(client, 3, time.Second)
	client = NewAuthHTTPClient(client, token)
	client = NewLoggingHTTPClient(client, logger)
	// All requests now have: logging, auth, retry, and caching.
	return client
}
```

### Stream Processing Decorators

```go
package streams

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"fmt"
	"io"
	"os"
)

// DataStream is the component interface.
type DataStream interface {
	Read(ctx context.Context) ([]byte, error)
	Write(ctx context.Context, data []byte) error
}

// FileStream is the concrete component.
type FileStream struct {
	path string
}

func NewFileStream(path string) *FileStream {
	return &FileStream{path: path}
}

func (s *FileStream) Read(ctx context.Context) ([]byte, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return nil, fmt.Errorf("read file %s: %w", s.path, err)
	}
	return data, nil
}

func (s *FileStream) Write(ctx context.Context, data []byte) error {
	if err := os.WriteFile(s.path, data, 0o600); err != nil {
		return fmt.Errorf("write file %s: %w", s.path, err)
	}
	return nil
}

// GzipStream decorates a stream with compression.
type GzipStream struct {
	next DataStream
}

func NewGzipStream(next DataStream) *GzipStream {
	return &GzipStream{next: next}
}

func (s *GzipStream) Read(ctx context.Context) ([]byte, error) {
	compressed, err := s.next.Read(ctx)
	if err != nil {
		return nil, err
	}
	r, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		return nil, fmt.Errorf("gzip reader: %w", err)
	}
	defer r.Close()

	data, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("gunzip: %w", err)
	}
	return data, nil
}

func (s *GzipStream) Write(ctx context.Context, data []byte) error {
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	if _, err := w.Write(data); err != nil {
		return fmt.Errorf("gzip write: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("gzip close: %w", err)
	}
	return s.next.Write(ctx, buf.Bytes())
}

// EncryptedStream decorates a stream with AES-256-GCM encryption.
type EncryptedStream struct {
	next DataStream
	key  []byte // 32 bytes for AES-256
}

func NewEncryptedStream(next DataStream, key []byte) *EncryptedStream {
	return &EncryptedStream{next: next, key: key}
}

func (s *EncryptedStream) Read(ctx context.Context) ([]byte, error) {
	ciphertext, err := s.next.Read(ctx)
	if err != nil {
		return nil, err
	}
	return s.decrypt(ciphertext)
}

func (s *EncryptedStream) Write(ctx context.Context, data []byte) error {
	ciphertext, err := s.encrypt(data)
	if err != nil {
		return err
	}
	return s.next.Write(ctx, ciphertext)
}

func (s *EncryptedStream) encrypt(plaintext []byte) ([]byte, error) {
	gcm, err := s.gcm()
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("read nonce: %w", err)
	}
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

func (s *EncryptedStream) decrypt(ciphertext []byte) ([]byte, error) {
	gcm, err := s.gcm()
	if err != nil {
		return nil, err
	}
	if len(ciphertext) < gcm.NonceSize() {
		return nil, fmt.Errorf("ciphertext too short")
	}
	nonce, enc := ciphertext[:gcm.NonceSize()], ciphertext[gcm.NonceSize():]
	plaintext, err := gcm.Open(nil, nonce, enc, nil)
	if err != nil {
		return nil, fmt.Errorf("gcm open: %w", err)
	}
	return plaintext, nil
}

func (s *EncryptedStream) gcm() (cipher.AEAD, error) {
	block, err := aes.NewCipher(s.key)
	if err != nil {
		return nil, fmt.Errorf("new cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("new gcm: %w", err)
	}
	return gcm, nil
}

// Usage
func run(ctx context.Context, key []byte) error {
	var stream DataStream = NewFileStream("/data/sensitive.txt")
	stream = NewGzipStream(stream)           // compress before encrypting
	stream = NewEncryptedStream(stream, key) // encrypt

	if err := stream.Write(ctx, []byte("Sensitive data")); err != nil { // compressed, then encrypted
		return err
	}
	_, err := stream.Read(ctx) // decrypted, then decompressed
	return err
}
```

### Validation Decorators

```go
package validation

import (
	"fmt"
	"regexp"
)

type ValidationResult struct {
	Valid  bool
	Errors []string
}

// Validator is generic over the value being validated.
type Validator[T any] interface {
	Validate(value T) ValidationResult
}

// RequiredValidator rejects the zero value of T.
type RequiredValidator[T comparable] struct{}

func (RequiredValidator[T]) Validate(value T) ValidationResult {
	var zero T
	if value == zero {
		return ValidationResult{Valid: false, Errors: []string{"value is required"}}
	}
	return ValidationResult{Valid: true}
}

// MinLengthValidator decorates a string validator with a lower bound.
type MinLengthValidator struct {
	inner     Validator[string]
	minLength int
}

func NewMinLengthValidator(inner Validator[string], minLength int) *MinLengthValidator {
	return &MinLengthValidator{inner: inner, minLength: minLength}
}

func (v *MinLengthValidator) Validate(value string) ValidationResult {
	if result := v.inner.Validate(value); !result.Valid {
		return result
	}
	if len(value) < v.minLength {
		return ValidationResult{Valid: false, Errors: []string{fmt.Sprintf("minimum length is %d", v.minLength)}}
	}
	return ValidationResult{Valid: true}
}

// MaxLengthValidator decorates with an upper bound.
type MaxLengthValidator struct {
	inner     Validator[string]
	maxLength int
}

func NewMaxLengthValidator(inner Validator[string], maxLength int) *MaxLengthValidator {
	return &MaxLengthValidator{inner: inner, maxLength: maxLength}
}

func (v *MaxLengthValidator) Validate(value string) ValidationResult {
	if result := v.inner.Validate(value); !result.Valid {
		return result
	}
	if len(value) > v.maxLength {
		return ValidationResult{Valid: false, Errors: []string{fmt.Sprintf("maximum length is %d", v.maxLength)}}
	}
	return ValidationResult{Valid: true}
}

// PatternValidator decorates with a regular-expression check.
type PatternValidator struct {
	inner   Validator[string]
	pattern *regexp.Regexp
	message string
}

func NewPatternValidator(inner Validator[string], pattern *regexp.Regexp, message string) *PatternValidator {
	return &PatternValidator{inner: inner, pattern: pattern, message: message}
}

func (v *PatternValidator) Validate(value string) ValidationResult {
	if result := v.inner.Validate(value); !result.Valid {
		return result
	}
	if !v.pattern.MatchString(value) {
		return ValidationResult{Valid: false, Errors: []string{v.message}}
	}
	return ValidationResult{Valid: true}
}

// Usage
func passwordCheck() ValidationResult {
	var v Validator[string] = RequiredValidator[string]{}
	v = NewMinLengthValidator(v, 8)
	v = NewMaxLengthValidator(v, 100)
	v = NewPatternValidator(v, regexp.MustCompile(`[A-Z]`), "must contain uppercase letter")
	v = NewPatternValidator(v, regexp.MustCompile(`[0-9]`), "must contain number")

	return v.Validate("weak") // invalid — fails on the first unmet rule
}
```

## Function Decorators (Higher-Order Functions)

```go
package service

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// Go has no annotation-style decorators. The idiomatic equivalent is a
// higher-order function: it takes a function and returns a wrapped one
// with added behavior. This is how cross-cutting concerns are layered.
type Handler[In, Out any] func(ctx context.Context, in In) (Out, error)

// WithLogging wraps a handler to log its call and result.
func WithLogging[In, Out any](name string, logger *slog.Logger, next Handler[In, Out]) Handler[In, Out] {
	return func(ctx context.Context, in In) (Out, error) {
		logger.Info("calling", "op", name, "in", in)
		out, err := next(ctx, in)
		if err != nil {
			logger.Error("failed", "op", name, "err", err)
			return out, err
		}
		logger.Info("returned", "op", name, "out", out)
		return out, nil
	}
}

// WithCaching wraps a handler with a TTL cache keyed by input.
func WithCaching[In comparable, Out any](ttl time.Duration, next Handler[In, Out]) Handler[In, Out] {
	type entry struct {
		value   Out
		expires time.Time
	}
	var (
		mu    sync.Mutex
		cache = make(map[In]entry)
	)
	return func(ctx context.Context, in In) (Out, error) {
		mu.Lock()
		e, ok := cache[in]
		mu.Unlock()
		if ok && e.expires.After(time.Now()) {
			return e.value, nil
		}

		out, err := next(ctx, in)
		if err != nil {
			return out, err
		}

		mu.Lock()
		cache[in] = entry{value: out, expires: time.Now().Add(ttl)}
		mu.Unlock()
		return out, nil
	}
}

// Usage — compose the wrappers around a method value.
func (s *UserService) GetUser(ctx context.Context, id string) (User, error) {
	// Expensive operation.
	return s.repo.FindByID(ctx, id)
}

func NewGetUserHandler(s *UserService, logger *slog.Logger) Handler[string, User] {
	return WithLogging("GetUser", logger, WithCaching[string, User](30*time.Second, s.GetUser))
}
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Flexibility | Add/remove behaviors at runtime |
| Composition | Combine behaviors in any order |
| Open/Closed | Extend without modifying existing code |
| Single Responsibility | Each decorator has one behavior |

## When to Use

- Adding responsibilities dynamically
- When inheritance causes class explosion
- Stream/filter processing pipelines
- Cross-cutting concerns (logging, caching, auth)
