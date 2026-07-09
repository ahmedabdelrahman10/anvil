---
name: strategy-pattern
description: Strategy pattern for interchangeable algorithms
category: architecture/design-patterns/behavioral
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Strategy Pattern

## Overview

The Strategy pattern defines a family of algorithms, encapsulates each one,
and makes them interchangeable. It lets the algorithm vary independently
from clients that use it.

## Problem

```go
package payment

// ❌ Monolithic type with a giant switch — a new payment type means editing it.
type PaymentProcessor struct{}

func (p *PaymentProcessor) Process(order Order, paymentType string) (PaymentResult, error) {
	switch paymentType {
	case "credit_card":
		// 50 lines of credit card logic:
		// validation, API calls, error handling...
	case "paypal":
		// 50 lines of PayPal logic:
		// OAuth, redirects, webhooks...
	case "bank_transfer":
		// 50 lines of bank transfer logic:
		// account validation, SWIFT codes...
	case "crypto":
		// 50 lines of crypto logic:
		// wallet addresses, blockchain verification...
	}
	// Adding a new payment type requires modifying this type.
	return PaymentResult{}, nil
}
```

## Solution: Strategy Pattern

```go
package payment

import (
	"context"
	"fmt"
)

// PaymentResult is the outcome of a payment attempt.
type PaymentResult struct {
	Success       bool
	TransactionID string
	Message       string
	RedirectURL   string
	WalletAddress string
	Amount        float64
	Errors        []string
}

// ValidationResult reports whether an order is payable by a strategy.
type ValidationResult struct {
	Valid  bool
	Errors []string
}

// ✅ PaymentStrategy is one interchangeable payment algorithm.
type PaymentStrategy interface {
	Process(ctx context.Context, order Order) (PaymentResult, error)
	Name() string
	Validate(order Order) ValidationResult
}

// CreditCardStrategy charges a card via a gateway.
type CreditCardStrategy struct {
	gateway CreditCardGateway
}

func NewCreditCardStrategy(gateway CreditCardGateway) *CreditCardStrategy {
	return &CreditCardStrategy{gateway: gateway}
}

func (s *CreditCardStrategy) Process(ctx context.Context, order Order) (PaymentResult, error) {
	result, err := s.gateway.Charge(ctx, ChargeRequest{
		Amount:     order.Total,
		CardNumber: order.PaymentDetails.CardNumber,
		Expiry:     order.PaymentDetails.Expiry,
		CVV:        order.PaymentDetails.CVV,
	})
	if err != nil {
		return PaymentResult{}, fmt.Errorf("charge card: %w", err)
	}
	return PaymentResult{
		Success:       result.Status == "approved",
		TransactionID: result.TransactionID,
		Message:       result.Message,
	}, nil
}

func (s *CreditCardStrategy) Name() string { return "Credit Card" }

func (s *CreditCardStrategy) Validate(order Order) ValidationResult {
	var errs []string
	if order.PaymentDetails.CardNumber == "" {
		errs = append(errs, "card number is required")
	}
	if order.PaymentDetails.CVV == "" {
		errs = append(errs, "CVV is required")
	}
	return ValidationResult{Valid: len(errs) == 0, Errors: errs}
}

// PayPalStrategy creates a PayPal payment.
type PayPalStrategy struct {
	client PayPalClient
}

func NewPayPalStrategy(client PayPalClient) *PayPalStrategy {
	return &PayPalStrategy{client: client}
}

func (s *PayPalStrategy) Process(ctx context.Context, order Order) (PaymentResult, error) {
	payment, err := s.client.CreatePayment(ctx, PayPalRequest{
		Amount:    order.Total,
		Currency:  order.Currency,
		ReturnURL: order.ReturnURL,
		CancelURL: order.CancelURL,
	})
	if err != nil {
		return PaymentResult{}, fmt.Errorf("create paypal payment: %w", err)
	}
	return PaymentResult{
		Success:       true,
		TransactionID: payment.ID,
		RedirectURL:   payment.ApprovalURL,
	}, nil
}

func (s *PayPalStrategy) Name() string { return "PayPal" }

func (s *PayPalStrategy) Validate(order Order) ValidationResult {
	return ValidationResult{Valid: true}
}

// CryptoStrategy creates a crypto invoice.
type CryptoStrategy struct {
	gateway CryptoGateway
}

func NewCryptoStrategy(gateway CryptoGateway) *CryptoStrategy {
	return &CryptoStrategy{gateway: gateway}
}

func (s *CryptoStrategy) Process(ctx context.Context, order Order) (PaymentResult, error) {
	cryptoCurrency := order.PaymentDetails.CryptoCurrency
	if cryptoCurrency == "" {
		cryptoCurrency = "BTC"
	}
	invoice, err := s.gateway.CreateInvoice(ctx, InvoiceRequest{
		Amount:         order.Total,
		Currency:       "USD",
		CryptoCurrency: cryptoCurrency,
	})
	if err != nil {
		return PaymentResult{}, fmt.Errorf("create crypto invoice: %w", err)
	}
	return PaymentResult{
		Success:       true,
		TransactionID: invoice.ID,
		WalletAddress: invoice.Address,
		Amount:        invoice.CryptoAmount,
	}, nil
}

func (s *CryptoStrategy) Name() string { return "Cryptocurrency" }

func (s *CryptoStrategy) Validate(order Order) ValidationResult {
	return ValidationResult{Valid: true}
}

// PaymentProcessor is the context that runs a chosen strategy.
type PaymentProcessor struct {
	strategy PaymentStrategy
}

func NewPaymentProcessor(strategy PaymentStrategy) *PaymentProcessor {
	return &PaymentProcessor{strategy: strategy}
}

func (p *PaymentProcessor) SetStrategy(strategy PaymentStrategy) {
	p.strategy = strategy
}

func (p *PaymentProcessor) ProcessPayment(ctx context.Context, order Order) (PaymentResult, error) {
	// Validate.
	if validation := p.strategy.Validate(order); !validation.Valid {
		return PaymentResult{Success: false, Errors: validation.Errors}, nil
	}
	// Process.
	return p.strategy.Process(ctx, order)
}

// Usage
func Example(ctx context.Context, creditCardGateway CreditCardGateway, paypalClient PayPalClient, order, anotherOrder Order) error {
	processor := NewPaymentProcessor(NewCreditCardStrategy(creditCardGateway))
	if _, err := processor.ProcessPayment(ctx, order); err != nil {
		return err
	}

	// Switch strategy at runtime.
	processor.SetStrategy(NewPayPalStrategy(paypalClient))
	_, err := processor.ProcessPayment(ctx, anotherOrder)
	return err
}
```

## Strategy Factory

```go
package payment

import "fmt"

// PaymentStrategyFactory builds strategies by type name using a dispatch map
// instead of a switch.
type PaymentStrategyFactory struct {
	strategies map[string]func() PaymentStrategy
}

func NewPaymentStrategyFactory(cc CreditCardGateway, pp PayPalClient, crypto CryptoGateway) *PaymentStrategyFactory {
	return &PaymentStrategyFactory{
		strategies: map[string]func() PaymentStrategy{
			"credit_card": func() PaymentStrategy { return NewCreditCardStrategy(cc) },
			"paypal":      func() PaymentStrategy { return NewPayPalStrategy(pp) },
			"crypto":      func() PaymentStrategy { return NewCryptoStrategy(crypto) },
		},
	}
}

func (f *PaymentStrategyFactory) Create(paymentType string) (PaymentStrategy, error) {
	build, ok := f.strategies[paymentType]
	if !ok {
		return nil, fmt.Errorf("unknown payment type: %s", paymentType)
	}
	return build(), nil
}

func (f *PaymentStrategyFactory) AvailableTypes() []string {
	types := make([]string, 0, len(f.strategies))
	for t := range f.strategies {
		types = append(types, t)
	}
	return types
}

// Usage
func ExampleFactory(creditCard CreditCardGateway, paypal PayPalClient, crypto CryptoGateway, order Order) (*PaymentProcessor, error) {
	factory := NewPaymentStrategyFactory(creditCard, paypal, crypto)
	strategy, err := factory.Create(order.PaymentType)
	if err != nil {
		return nil, err
	}
	return NewPaymentProcessor(strategy), nil
}
```

## Real-World Examples

### Compression Strategy

```go
package compression

import (
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"fmt"
	"io"
	"os"
)

// CompressionStrategy is one interchangeable compression algorithm. Compression
// is pure CPU work with no cancellation point, so it needs no ctx.
type CompressionStrategy interface {
	Compress(data []byte) ([]byte, error)
	Decompress(data []byte) ([]byte, error)
	Extension() string
}

// GzipStrategy compresses with gzip.
type GzipStrategy struct{}

func (GzipStrategy) Compress(data []byte) ([]byte, error) {
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	if _, err := w.Write(data); err != nil {
		return nil, fmt.Errorf("gzip write: %w", err)
	}
	if err := w.Close(); err != nil {
		return nil, fmt.Errorf("gzip close: %w", err)
	}
	return buf.Bytes(), nil
}

func (GzipStrategy) Decompress(data []byte) ([]byte, error) {
	r, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("gzip reader: %w", err)
	}
	defer r.Close()
	out, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("gzip read: %w", err)
	}
	return out, nil
}

func (GzipStrategy) Extension() string { return ".gz" }

// ZlibStrategy compresses with zlib (DEFLATE).
type ZlibStrategy struct{}

func (ZlibStrategy) Compress(data []byte) ([]byte, error) {
	var buf bytes.Buffer
	w := zlib.NewWriter(&buf)
	if _, err := w.Write(data); err != nil {
		return nil, fmt.Errorf("zlib write: %w", err)
	}
	if err := w.Close(); err != nil {
		return nil, fmt.Errorf("zlib close: %w", err)
	}
	return buf.Bytes(), nil
}

func (ZlibStrategy) Decompress(data []byte) ([]byte, error) {
	r, err := zlib.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("zlib reader: %w", err)
	}
	defer r.Close()
	out, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("zlib read: %w", err)
	}
	return out, nil
}

func (ZlibStrategy) Extension() string { return ".zz" }

// NoCompressionStrategy passes data through unchanged.
type NoCompressionStrategy struct{}

func (NoCompressionStrategy) Compress(data []byte) ([]byte, error)   { return data, nil }
func (NoCompressionStrategy) Decompress(data []byte) ([]byte, error) { return data, nil }
func (NoCompressionStrategy) Extension() string                      { return "" }

// FileArchiver combines files and writes them using a compression strategy.
type FileArchiver struct {
	compression CompressionStrategy
}

func NewFileArchiver(compression CompressionStrategy) *FileArchiver {
	return &FileArchiver{compression: compression}
}

func (a *FileArchiver) Archive(files []File, outputPath string) error {
	// Combine files.
	combined, err := combineFiles(files)
	if err != nil {
		return fmt.Errorf("combine files: %w", err)
	}
	// Compress using the strategy.
	compressed, err := a.compression.Compress(combined)
	if err != nil {
		return fmt.Errorf("compress: %w", err)
	}
	// Write to output with the appropriate extension.
	finalPath := outputPath + a.compression.Extension()
	if err := os.WriteFile(finalPath, compressed, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", finalPath, err)
	}
	return nil
}

func combineFiles(files []File) ([]byte, error) {
	var buf bytes.Buffer
	for _, f := range files {
		data, err := f.Read()
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", f.Name(), err)
		}
		buf.Write(data)
	}
	return buf.Bytes(), nil
}
```

### Sorting Strategy

```go
package sorting

// SortStrategy is one interchangeable sort algorithm. compare returns <0, 0, or
// >0, like the standard library's cmp.Compare.
type SortStrategy[T any] interface {
	Sort(items []T) []T
	Name() string
}

// QuickSortStrategy sorts using quicksort.
type QuickSortStrategy[T any] struct {
	compare func(a, b T) int
}

func NewQuickSortStrategy[T any](compare func(a, b T) int) *QuickSortStrategy[T] {
	return &QuickSortStrategy[T]{compare: compare}
}

func (s *QuickSortStrategy[T]) Sort(items []T) []T {
	if len(items) <= 1 {
		return items
	}
	pivot := items[len(items)/2]
	var left, middle, right []T
	for _, item := range items {
		switch c := s.compare(item, pivot); {
		case c < 0:
			left = append(left, item)
		case c == 0:
			middle = append(middle, item)
		default:
			right = append(right, item)
		}
	}
	result := make([]T, 0, len(items))
	result = append(result, s.Sort(left)...)
	result = append(result, middle...)
	result = append(result, s.Sort(right)...)
	return result
}

func (s *QuickSortStrategy[T]) Name() string { return "Quick Sort" }

// MergeSortStrategy sorts using mergesort.
type MergeSortStrategy[T any] struct {
	compare func(a, b T) int
}

func NewMergeSortStrategy[T any](compare func(a, b T) int) *MergeSortStrategy[T] {
	return &MergeSortStrategy[T]{compare: compare}
}

func (s *MergeSortStrategy[T]) Sort(items []T) []T {
	if len(items) <= 1 {
		return items
	}
	mid := len(items) / 2
	left := s.Sort(items[:mid])
	right := s.Sort(items[mid:])
	return s.merge(left, right)
}

func (s *MergeSortStrategy[T]) merge(left, right []T) []T {
	result := make([]T, 0, len(left)+len(right))
	i, j := 0, 0
	for i < len(left) && j < len(right) {
		if s.compare(left[i], right[j]) <= 0 {
			result = append(result, left[i])
			i++
		} else {
			result = append(result, right[j])
			j++
		}
	}
	result = append(result, left[i:]...)
	result = append(result, right[j:]...)
	return result
}

func (s *MergeSortStrategy[T]) Name() string { return "Merge Sort" }

// AdaptiveSortStrategy picks quicksort for small inputs, mergesort for large.
type AdaptiveSortStrategy[T any] struct {
	compare   func(a, b T) int
	threshold int
}

func NewAdaptiveSortStrategy[T any](compare func(a, b T) int, threshold int) *AdaptiveSortStrategy[T] {
	if threshold <= 0 {
		threshold = 1000
	}
	return &AdaptiveSortStrategy[T]{compare: compare, threshold: threshold}
}

func (s *AdaptiveSortStrategy[T]) Sort(items []T) []T {
	// Use quicksort for small arrays, mergesort for large.
	var strategy SortStrategy[T]
	if len(items) < s.threshold {
		strategy = NewQuickSortStrategy(s.compare)
	} else {
		strategy = NewMergeSortStrategy(s.compare)
	}
	return strategy.Sort(items)
}

func (s *AdaptiveSortStrategy[T]) Name() string { return "Adaptive Sort" }
```

### Pricing Strategy

```go
package pricing

import (
	"fmt"
	"sort"
	"time"
)

// Customer is the pricing subject.
type Customer struct {
	IsVIP                bool
	CurrentOrderQuantity int
}

// PriceResult is a computed price with provenance.
type PriceResult struct {
	BasePrice   float64
	FinalPrice  float64
	Strategy    string
	Description string
	Savings     float64
}

// PricingStrategy computes a price from a base price and customer.
type PricingStrategy interface {
	CalculatePrice(basePrice float64, customer Customer) float64
	Description() string
}

// RegularPricingStrategy applies no discount.
type RegularPricingStrategy struct{}

func (RegularPricingStrategy) CalculatePrice(basePrice float64, _ Customer) float64 {
	return basePrice
}

func (RegularPricingStrategy) Description() string { return "Regular pricing" }

// VIPPricingStrategy applies a percentage discount.
type VIPPricingStrategy struct {
	discountPercent float64
}

func NewVIPPricingStrategy(discountPercent float64) *VIPPricingStrategy {
	return &VIPPricingStrategy{discountPercent: discountPercent}
}

func (s *VIPPricingStrategy) CalculatePrice(basePrice float64, _ Customer) float64 {
	return basePrice * (1 - s.discountPercent/100)
}

func (s *VIPPricingStrategy) Description() string {
	return fmt.Sprintf("VIP pricing (%.0f%% discount)", s.discountPercent)
}

// SeasonalPricingStrategy multiplies by a season factor.
type SeasonalPricingStrategy struct {
	multiplier float64
	season     string
}

func NewSeasonalPricingStrategy(multiplier float64, season string) *SeasonalPricingStrategy {
	return &SeasonalPricingStrategy{multiplier: multiplier, season: season}
}

func (s *SeasonalPricingStrategy) CalculatePrice(basePrice float64, _ Customer) float64 {
	return basePrice * s.multiplier
}

func (s *SeasonalPricingStrategy) Description() string {
	return fmt.Sprintf("%s pricing (%.2fx)", s.season, s.multiplier)
}

// BulkTier is a quantity threshold and its discount percentage.
type BulkTier struct {
	MinQuantity int
	Discount    float64
}

// BulkPricingStrategy applies the best tier the quantity qualifies for.
type BulkPricingStrategy struct {
	tiers []BulkTier
}

func NewBulkPricingStrategy(tiers []BulkTier) *BulkPricingStrategy {
	sorted := append([]BulkTier(nil), tiers...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].MinQuantity > sorted[j].MinQuantity })
	return &BulkPricingStrategy{tiers: sorted}
}

func (s *BulkPricingStrategy) CalculatePrice(basePrice float64, customer Customer) float64 {
	var discount float64
	for _, tier := range s.tiers {
		if customer.CurrentOrderQuantity >= tier.MinQuantity {
			discount = tier.Discount
			break
		}
	}
	return basePrice * (1 - discount/100)
}

func (s *BulkPricingStrategy) Description() string { return "Bulk pricing" }

// PricingEngine selects and applies a strategy per customer.
type PricingEngine struct {
	strategies      map[string]PricingStrategy
	defaultStrategy PricingStrategy
	now             func() time.Time // injected for testability; no time.Now in logic
}

func NewPricingEngine() *PricingEngine {
	return &PricingEngine{
		defaultStrategy: RegularPricingStrategy{},
		now:             time.Now,
		strategies: map[string]PricingStrategy{
			"regular": RegularPricingStrategy{},
			"vip":     NewVIPPricingStrategy(20),
			"holiday": NewSeasonalPricingStrategy(1.25, "Holiday"),
			"bulk": NewBulkPricingStrategy([]BulkTier{
				{MinQuantity: 100, Discount: 15},
				{MinQuantity: 50, Discount: 10},
				{MinQuantity: 20, Discount: 5},
			}),
		},
	}
}

func (e *PricingEngine) CalculatePrice(basePrice float64, customer Customer) PriceResult {
	key := e.selectStrategy(customer)
	strategy, ok := e.strategies[key]
	if !ok {
		strategy = e.defaultStrategy
	}
	finalPrice := strategy.CalculatePrice(basePrice, customer)

	return PriceResult{
		BasePrice:   basePrice,
		FinalPrice:  finalPrice,
		Strategy:    key,
		Description: strategy.Description(),
		Savings:     basePrice - finalPrice,
	}
}

func (e *PricingEngine) selectStrategy(customer Customer) string {
	switch {
	case customer.IsVIP:
		return "vip"
	case customer.CurrentOrderQuantity >= 20:
		return "bulk"
	case e.isHolidaySeason():
		return "holiday"
	default:
		return "regular"
	}
}

func (e *PricingEngine) isHolidaySeason() bool {
	month := e.now().Month()
	return month == time.December || month == time.January // Dec or Jan
}
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Open/Closed | Add new strategies without modifying context |
| Single Responsibility | Each strategy handles one algorithm |
| Runtime Flexibility | Switch algorithms at runtime |
| Testability | Strategies can be tested independently |
| Eliminates Conditionals | No switch/if-else for algorithm selection |

## When to Use

- Multiple algorithms for a task
- Need to switch algorithms at runtime
- Class has multiple conditional behaviors
- Algorithm implementations should be independent
