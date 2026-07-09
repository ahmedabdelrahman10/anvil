---
name: adapter-pattern
description: Adapter pattern for interface compatibility
category: architecture/design-patterns/structural
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Adapter Pattern

## Overview

The Adapter pattern converts the interface of a class into another
interface that clients expect. It allows classes with incompatible
interfaces to work together.

## Problem

```go
package payment

import (
	"context"

	"github.com/stripe/stripe-go/v78"
)

// PaymentResult and RefundResult are your domain types.
type PaymentResult struct {
	Success       bool
	TransactionID string
	Amount        float64
	Currency      string
}

type RefundResult struct {
	Success  bool
	RefundID string
	Amount   float64
}

// PaymentGateway is the small, consumer-defined interface your code expects.
type PaymentGateway interface {
	Charge(ctx context.Context, amount float64, currency string) (PaymentResult, error)
	Refund(ctx context.Context, transactionID string) (RefundResult, error)
}

// The third-party Stripe SDK exposes a different shape:
//
//	func (c *stripe.Client) CreatePaymentIntent(ctx, *stripe.PaymentIntentParams) (*stripe.PaymentIntent, error)
//	func (c *stripe.Client) CreateRefund(ctx, *stripe.RefundParams) (*stripe.Refund, error)
//
// Problem: *stripe.Client does not satisfy PaymentGateway.
// var gateway PaymentGateway = &stripe.Client{} // compile error!
```

## Solution: Adapter

```go
package payment

import (
	"context"
	"fmt"
	"math"
	"strings"

	"github.com/stripe/stripe-go/v78"
)

// StripeAdapter wraps the Stripe SDK and satisfies PaymentGateway.
type StripeAdapter struct {
	client *stripe.Client
}

func NewStripeAdapter(client *stripe.Client) *StripeAdapter {
	return &StripeAdapter{client: client}
}

func (a *StripeAdapter) Charge(ctx context.Context, amount float64, currency string) (PaymentResult, error) {
	intent, err := a.client.CreatePaymentIntent(ctx, &stripe.PaymentIntentParams{
		Amount:             int64(math.Round(amount * 100)), // convert to cents
		Currency:           strings.ToLower(currency),
		PaymentMethodTypes: []string{"card"},
	})
	if err != nil {
		return PaymentResult{}, fmt.Errorf("stripe: create payment intent: %w", err)
	}

	return PaymentResult{
		Success:       intent.Status == "succeeded",
		TransactionID: intent.ID,
		Amount:        float64(intent.Amount) / 100,
		Currency:      strings.ToUpper(intent.Currency),
	}, nil
}

func (a *StripeAdapter) Refund(ctx context.Context, transactionID string) (RefundResult, error) {
	refund, err := a.client.CreateRefund(ctx, &stripe.RefundParams{
		PaymentIntent: transactionID,
	})
	if err != nil {
		return RefundResult{}, fmt.Errorf("stripe: create refund: %w", err)
	}

	return RefundResult{
		Success:  refund.Status == "succeeded",
		RefundID: refund.ID,
		Amount:   float64(refund.Amount) / 100,
	}, nil
}

// Compile-time proof that the adapter satisfies the consumer interface.
var _ PaymentGateway = (*StripeAdapter)(nil)

// gateway := NewStripeAdapter(stripeClient)
// gateway.Charge(ctx, 99.99, "USD")
```

## Object Adapter vs Class Adapter

### Object Adapter (Composition) - Preferred

```go
// Uses composition — the adapter HAS-A adaptee.
type PayPalAdapter struct {
	paypal *paypal.Client
}

func NewPayPalAdapter(client *paypal.Client) *PayPalAdapter {
	return &PayPalAdapter{paypal: client}
}

func (a *PayPalAdapter) Charge(ctx context.Context, amount float64, currency string) (PaymentResult, error) {
	order, err := a.paypal.CreateOrder(ctx, &paypal.OrderParams{
		Intent: "CAPTURE",
		PurchaseUnits: []paypal.PurchaseUnit{{
			Amount: paypal.Money{Value: fmt.Sprintf("%.2f", amount), CurrencyCode: currency},
		}},
	})
	if err != nil {
		return PaymentResult{}, fmt.Errorf("paypal: create order: %w", err)
	}
	return a.toPaymentResult(order), nil
}

// ... other methods
```

### Class Adapter (Inheritance) - Less Flexible

```go
// Go has no inheritance. The nearest analogue is embedding the adaptee,
// which promotes ALL of its methods onto the adapter — leaking the very
// interface you meant to hide. Prefer composition (above).
type PayPalAdapter struct {
	*paypal.Client // embedded: PayPalAdapter now exposes every paypal.Client method
}

func (a *PayPalAdapter) Charge(ctx context.Context, amount float64, currency string) (PaymentResult, error) {
	order, err := a.CreateOrder(ctx, &paypal.OrderParams{ /* ... */ })
	if err != nil {
		return PaymentResult{}, fmt.Errorf("paypal: create order: %w", err)
	}
	return a.toPaymentResult(order), nil
}
```

## Real-World Examples

### Database Adapter

```go
package storage

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Database is a small consumer-defined interface over a SQL backend.
type Database interface {
	Connect(ctx context.Context) error
	Query(ctx context.Context, query string, args ...any) ([]map[string]any, error)
	Exec(ctx context.Context, query string, args ...any) error
	Close(ctx context.Context) error
}

// PostgreSQLAdapter adapts a pgx pool to the Database interface.
type PostgreSQLAdapter struct {
	pool *pgxpool.Pool
}

func NewPostgreSQLAdapter(pool *pgxpool.Pool) *PostgreSQLAdapter {
	return &PostgreSQLAdapter{pool: pool}
}

func (a *PostgreSQLAdapter) Connect(ctx context.Context) error {
	if err := a.pool.Ping(ctx); err != nil {
		return fmt.Errorf("postgres: ping: %w", err)
	}
	return nil
}

func (a *PostgreSQLAdapter) Query(ctx context.Context, query string, args ...any) ([]map[string]any, error) {
	rows, err := a.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("postgres: query: %w", err)
	}
	defer rows.Close()

	out, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		return nil, fmt.Errorf("postgres: collect rows: %w", err)
	}
	return out, nil
}

func (a *PostgreSQLAdapter) Exec(ctx context.Context, query string, args ...any) error {
	if _, err := a.pool.Exec(ctx, query, args...); err != nil {
		return fmt.Errorf("postgres: exec: %w", err)
	}
	return nil
}

func (a *PostgreSQLAdapter) Close(ctx context.Context) error {
	a.pool.Close()
	return nil
}

// MySQLAdapter adapts a database/sql handle to the same interface.
type MySQLAdapter struct {
	db *sql.DB
}

func NewMySQLAdapter(db *sql.DB) *MySQLAdapter {
	return &MySQLAdapter{db: db}
}

func (a *MySQLAdapter) Connect(ctx context.Context) error {
	if err := a.db.PingContext(ctx); err != nil {
		return fmt.Errorf("mysql: ping: %w", err)
	}
	return nil
}

func (a *MySQLAdapter) Query(ctx context.Context, query string, args ...any) ([]map[string]any, error) {
	rows, err := a.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("mysql: query: %w", err)
	}
	defer rows.Close()

	cols, err := rows.Columns()
	if err != nil {
		return nil, fmt.Errorf("mysql: columns: %w", err)
	}

	var out []map[string]any
	for rows.Next() {
		values := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range values {
			ptrs[i] = &values[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, fmt.Errorf("mysql: scan: %w", err)
		}
		row := make(map[string]any, len(cols))
		for i, c := range cols {
			row[c] = values[i]
		}
		out = append(out, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("mysql: rows: %w", err)
	}
	return out, nil
}

func (a *MySQLAdapter) Exec(ctx context.Context, query string, args ...any) error {
	if _, err := a.db.ExecContext(ctx, query, args...); err != nil {
		return fmt.Errorf("mysql: exec: %w", err)
	}
	return nil
}

func (a *MySQLAdapter) Close(ctx context.Context) error {
	if err := a.db.Close(); err != nil {
		return fmt.Errorf("mysql: close: %w", err)
	}
	return nil
}

// Application code works with any Database implementation.
type UserRepository struct {
	db Database
}

func NewUserRepository(db Database) *UserRepository {
	return &UserRepository{db: db}
}

func (r *UserRepository) FindByID(ctx context.Context, id string) (*User, error) {
	rows, err := r.db.Query(ctx, "SELECT id, email, name FROM users WHERE id = $1", id)
	if err != nil {
		return nil, fmt.Errorf("find user by id: %w", err)
	}
	if len(rows) == 0 {
		return nil, nil
	}
	return userFromRow(rows[0]), nil
}
```

### Logger Adapter

```go
package logging

import (
	"github.com/rs/zerolog"
	"go.uber.org/zap"
)

// Logger is the application-facing logging interface.
type Logger interface {
	Debug(msg string, fields map[string]any)
	Info(msg string, fields map[string]any)
	Warn(msg string, fields map[string]any)
	Error(msg string, err error, fields map[string]any)
}

// ZapAdapter adapts a *zap.Logger to Logger.
type ZapAdapter struct {
	logger *zap.Logger
}

func NewZapAdapter(logger *zap.Logger) *ZapAdapter {
	return &ZapAdapter{logger: logger}
}

func (a *ZapAdapter) Debug(msg string, fields map[string]any) {
	a.logger.Debug(msg, zapFields(fields)...)
}

func (a *ZapAdapter) Info(msg string, fields map[string]any) {
	a.logger.Info(msg, zapFields(fields)...)
}

func (a *ZapAdapter) Warn(msg string, fields map[string]any) {
	a.logger.Warn(msg, zapFields(fields)...)
}

func (a *ZapAdapter) Error(msg string, err error, fields map[string]any) {
	f := zapFields(fields)
	if err != nil {
		f = append(f, zap.Error(err))
	}
	a.logger.Error(msg, f...)
}

func zapFields(fields map[string]any) []zap.Field {
	out := make([]zap.Field, 0, len(fields))
	for k, v := range fields {
		out = append(out, zap.Any(k, v))
	}
	return out
}

// ZerologAdapter adapts a zerolog.Logger to the same interface.
type ZerologAdapter struct {
	logger zerolog.Logger
}

func NewZerologAdapter(logger zerolog.Logger) *ZerologAdapter {
	return &ZerologAdapter{logger: logger}
}

func (a *ZerologAdapter) Debug(msg string, fields map[string]any) {
	a.logger.Debug().Fields(fields).Msg(msg)
}

func (a *ZerologAdapter) Info(msg string, fields map[string]any) {
	a.logger.Info().Fields(fields).Msg(msg)
}

func (a *ZerologAdapter) Warn(msg string, fields map[string]any) {
	a.logger.Warn().Fields(fields).Msg(msg)
}

func (a *ZerologAdapter) Error(msg string, err error, fields map[string]any) {
	a.logger.Error().Err(err).Fields(fields).Msg(msg)
}
```

### External API Adapter

```go
package weather

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// WeatherService is the internal weather interface.
type WeatherService interface {
	CurrentWeather(ctx context.Context, city string) (Weather, error)
	Forecast(ctx context.Context, city string, days int) ([]Forecast, error)
}

type Weather struct {
	TemperatureC float64 // Celsius
	Humidity     int     // percentage
	Description  string
	WindSpeedKPH float64 // km/h
}

type Forecast struct {
	Date         time.Time
	TemperatureC float64
	Description  string
}

// OpenWeatherMapAdapter adapts the OpenWeatherMap API to WeatherService.
type OpenWeatherMapAdapter struct {
	apiKey string
	http   *http.Client
}

func NewOpenWeatherMapAdapter(apiKey string, client *http.Client) *OpenWeatherMapAdapter {
	return &OpenWeatherMapAdapter{apiKey: apiKey, http: client}
}

func (a *OpenWeatherMapAdapter) CurrentWeather(ctx context.Context, city string) (Weather, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.openweathermap.org/data/2.5/weather", nil)
	if err != nil {
		return Weather{}, fmt.Errorf("openweathermap: build request: %w", err)
	}
	q := req.URL.Query()
	q.Set("q", city)
	q.Set("appid", a.apiKey)
	q.Set("units", "metric")
	req.URL.RawQuery = q.Encode()

	resp, err := a.http.Do(req)
	if err != nil {
		return Weather{}, fmt.Errorf("openweathermap: do request: %w", err)
	}
	defer resp.Body.Close()

	var body struct {
		Main struct {
			Temp     float64 `json:"temp"`
			Humidity int     `json:"humidity"`
		} `json:"main"`
		Weather []struct {
			Description string `json:"description"`
		} `json:"weather"`
		Wind struct {
			Speed float64 `json:"speed"`
		} `json:"wind"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return Weather{}, fmt.Errorf("openweathermap: decode: %w", err)
	}

	// Transform the external format into the internal model.
	w := Weather{
		TemperatureC: body.Main.Temp,
		Humidity:     body.Main.Humidity,
		WindSpeedKPH: body.Wind.Speed * 3.6, // m/s to km/h
	}
	if len(body.Weather) > 0 {
		w.Description = body.Weather[0].Description
	}
	return w, nil
}

func (a *OpenWeatherMapAdapter) Forecast(ctx context.Context, city string, days int) ([]Forecast, error) {
	// Similar request against /forecast with cnt=days*8, then transformed
	// from the API-specific list into []Forecast. Omitted for brevity.
	return nil, nil
}

// WeatherAPIAdapter adapts a different API to the same interface.
type WeatherAPIAdapter struct {
	apiKey string
	http   *http.Client
}

func NewWeatherAPIAdapter(apiKey string, client *http.Client) *WeatherAPIAdapter {
	return &WeatherAPIAdapter{apiKey: apiKey, http: client}
}

func (a *WeatherAPIAdapter) CurrentWeather(ctx context.Context, city string) (Weather, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.weatherapi.com/v1/current.json", nil)
	if err != nil {
		return Weather{}, fmt.Errorf("weatherapi: build request: %w", err)
	}
	q := req.URL.Query()
	q.Set("key", a.apiKey)
	q.Set("q", city)
	req.URL.RawQuery = q.Encode()

	resp, err := a.http.Do(req)
	if err != nil {
		return Weather{}, fmt.Errorf("weatherapi: do request: %w", err)
	}
	defer resp.Body.Close()

	var body struct {
		Current struct {
			TempC     float64 `json:"temp_c"`
			Humidity  int     `json:"humidity"`
			WindKPH   float64 `json:"wind_kph"`
			Condition struct {
				Text string `json:"text"`
			} `json:"condition"`
		} `json:"current"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return Weather{}, fmt.Errorf("weatherapi: decode: %w", err)
	}

	return Weather{
		TemperatureC: body.Current.TempC,
		Humidity:     body.Current.Humidity,
		Description:  body.Current.Condition.Text,
		WindSpeedKPH: body.Current.WindKPH,
	}, nil
}

func (a *WeatherAPIAdapter) Forecast(ctx context.Context, city string, days int) ([]Forecast, error) {
	// Implementation for WeatherAPI.com.
	return nil, nil
}
```

## Anti-Corruption Layer

```go
package inventory

import (
	"context"
	"fmt"
	"strings"
)

// In DDD, adapters form the Anti-Corruption Layer between bounded contexts.
type InventoryACL struct {
	legacy *legacyinventory.Client
}

func NewInventoryACL(client *legacyinventory.Client) *InventoryACL {
	return &InventoryACL{legacy: client}
}

func (l *InventoryACL) CheckStock(ctx context.Context, productID string) (StockStatus, error) {
	// Call the legacy system in its own vocabulary.
	resp, err := l.legacy.GetItemAvailability(ctx, toLegacyProductCode(productID))
	if err != nil {
		return StockStatus{}, fmt.Errorf("legacy inventory: get availability: %w", err)
	}

	// Translate into our domain model.
	return StockStatus{
		ProductID:         productID,
		Available:         resp.QtyAvailable > 0,
		Quantity:          resp.QtyAvailable,
		WarehouseLocation: mapWarehouse(resp.WhseID),
	}, nil
}

func toLegacyProductCode(productID string) string {
	// Convert our product ID format to the legacy system's format.
	return "PROD-" + strings.ToUpper(productID)
}

func mapWarehouse(legacyWarehouseID string) string {
	switch legacyWarehouseID {
	case "WH001":
		return "warehouse-east"
	case "WH002":
		return "warehouse-west"
	case "WH003":
		return "warehouse-central"
	default:
		return "unknown"
	}
}
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Compatibility | Makes incompatible interfaces work together |
| Reusability | Reuse existing code without modification |
| Single Responsibility | Conversion logic isolated in adapter |
| Flexibility | Easy to switch implementations |

## When to Use

- Integrating third-party libraries
- Working with legacy systems
- Creating unified interfaces for multiple services
- Building anti-corruption layers in DDD
