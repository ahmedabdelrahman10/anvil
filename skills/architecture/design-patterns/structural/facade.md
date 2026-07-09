---
name: facade-pattern
description: Facade pattern for simplified interfaces
category: architecture/design-patterns/structural
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Facade Pattern

## Overview

The Facade pattern provides a unified interface to a set of interfaces
in a subsystem. It defines a higher-level interface that makes the
subsystem easier to use.

## Problem

```go
// The client must know and coordinate every subsystem.
type OrderProcessor struct{}

func (p *OrderProcessor) ProcessOrder(ctx context.Context, order OrderData) error {
	// Client must construct all subsystems.
	inventory := NewInventoryService()
	payment := NewPaymentGateway()
	shipping := NewShippingService()
	notification := NewNotificationService()
	analytics := NewAnalyticsService()
	fraud := NewFraudDetectionService()

	// Client must coordinate them in the right order.
	if err := fraud.Check(ctx, order); err != nil {
		return err
	}
	if err := inventory.Reserve(ctx, order.Items); err != nil {
		return err
	}
	if err := payment.Charge(ctx, order.PaymentDetails); err != nil {
		return err
	}
	shipment, err := shipping.CreateShipment(ctx, order)
	if err != nil {
		return err
	}
	if err := notification.SendConfirmation(ctx, order.Email, shipment); err != nil {
		return err
	}
	if err := analytics.TrackOrder(ctx, order); err != nil {
		return err
	}

	// What if payment fails after inventory is reserved?
	// The client must handle every error case and roll back.
	return nil
}
```

## Solution: Facade

```go
package order

import (
	"context"
	"errors"
	"fmt"
)

var (
	ErrFraudDetected = errors.New("order flagged as fraudulent")
	ErrOutOfStock    = errors.New("item out of stock")
)

// OrderFacade hides subsystem complexity behind a simple interface.
type OrderFacade struct {
	inventory    *InventoryService
	payment      PaymentGateway
	shipping     *ShippingService
	notification *NotificationService
	analytics    *AnalyticsService
	fraud        *FraudDetectionService
}

func NewOrderFacade(
	inventory *InventoryService,
	payment PaymentGateway,
	shipping *ShippingService,
	notification *NotificationService,
	analytics *AnalyticsService,
	fraud *FraudDetectionService,
) *OrderFacade {
	return &OrderFacade{
		inventory:    inventory,
		payment:      payment,
		shipping:     shipping,
		notification: notification,
		analytics:    analytics,
		fraud:        fraud,
	}
}

func (f *OrderFacade) PlaceOrder(ctx context.Context, order OrderData) (OrderResult, error) {
	// The facade coordinates all subsystems.
	if err := f.validateOrder(ctx, order); err != nil {
		f.handleFailure(ctx, order, err)
		return OrderResult{}, err
	}
	if err := f.processPayment(ctx, order); err != nil {
		f.handleFailure(ctx, order, err)
		return OrderResult{}, err
	}
	shipment, err := f.arrangeShipping(ctx, order)
	if err != nil {
		f.handleFailure(ctx, order, err)
		return OrderResult{}, err
	}
	if err := f.notifyCustomer(ctx, order, shipment); err != nil {
		f.handleFailure(ctx, order, err)
		return OrderResult{}, err
	}
	if err := f.trackAnalytics(ctx, order); err != nil {
		f.handleFailure(ctx, order, err)
		return OrderResult{}, err
	}

	return OrderResult{Success: true, OrderID: order.ID, Shipment: shipment}, nil
}

func (f *OrderFacade) validateOrder(ctx context.Context, order OrderData) error {
	// Fraud check.
	result, err := f.fraud.Check(ctx, order)
	if err != nil {
		return fmt.Errorf("fraud check: %w", err)
	}
	if result.Suspicious {
		return fmt.Errorf("%w: %s", ErrFraudDetected, result.Reason)
	}

	// Inventory check.
	for _, item := range order.Items {
		available, err := f.inventory.CheckStock(ctx, item.ProductID, item.Quantity)
		if err != nil {
			return fmt.Errorf("check stock %s: %w", item.ProductID, err)
		}
		if !available {
			return fmt.Errorf("%w: %s", ErrOutOfStock, item.ProductID)
		}
	}
	return nil
}

func (f *OrderFacade) processPayment(ctx context.Context, order OrderData) error {
	// Reserve inventory first.
	reservationID, err := f.inventory.Reserve(ctx, order.Items)
	if err != nil {
		return fmt.Errorf("reserve inventory: %w", err)
	}

	if _, err := f.payment.Charge(ctx, order.Total, order.Currency); err != nil {
		// Roll back on payment failure.
		if relErr := f.inventory.Release(ctx, reservationID); relErr != nil {
			return errors.Join(fmt.Errorf("charge payment: %w", err), fmt.Errorf("release reservation: %w", relErr))
		}
		return fmt.Errorf("charge payment: %w", err)
	}
	return nil
}

func (f *OrderFacade) arrangeShipping(ctx context.Context, order OrderData) (Shipment, error) {
	shipment, err := f.shipping.CreateShipment(ctx, ShipmentRequest{
		Items:   order.Items,
		Address: order.ShippingAddress,
		Method:  order.ShippingMethod,
	})
	if err != nil {
		return Shipment{}, fmt.Errorf("create shipment: %w", err)
	}
	return shipment, nil
}

func (f *OrderFacade) notifyCustomer(ctx context.Context, order OrderData, shipment Shipment) error {
	if err := f.notification.SendOrderConfirmation(ctx, OrderConfirmation{
		Email:          order.Email,
		OrderID:        order.ID,
		TrackingNumber: shipment.TrackingNumber,
	}); err != nil {
		return fmt.Errorf("send confirmation: %w", err)
	}
	return nil
}

func (f *OrderFacade) trackAnalytics(ctx context.Context, order OrderData) error {
	if err := f.analytics.Track(ctx, "order_placed", map[string]any{
		"orderId":   order.ID,
		"total":     order.Total,
		"itemCount": len(order.Items),
	}); err != nil {
		return fmt.Errorf("track analytics: %w", err)
	}
	return nil
}

func (f *OrderFacade) handleFailure(ctx context.Context, order OrderData, cause error) {
	// Best-effort; failure tracking must not mask the original error.
	_ = f.analytics.Track(ctx, "order_failed", map[string]any{
		"orderId": order.ID,
		"error":   cause.Error(),
	})
}

// Client code is now simple:
//
//	facade := NewOrderFacade(/* ... dependencies ... */)
//	result, err := facade.PlaceOrder(ctx, order)
```

## Real-World Examples

### Email Service Facade

```go
package email

import (
	"context"
	"errors"
	"fmt"
	"net/url"
)

var ErrBouncedEmail = errors.New("recipient address has bounced")

// Complex subsystems (fields omitted).
type (
	SMTPClient          struct{}
	TemplateEngine      struct{}
	AttachmentProcessor struct{}
	EmailValidator      struct{}
	EmailQueue          struct{}
	BounceHandler       struct{}
)

// EmailFacade simplifies email operations over the subsystems.
type EmailFacade struct {
	smtp        *SMTPClient
	templates   *TemplateEngine
	attachments *AttachmentProcessor
	validator   *EmailValidator
	queue       *EmailQueue
	bounces     *BounceHandler
	appURL      string
	defaultFrom string
}

func NewEmailFacade(
	smtp *SMTPClient,
	templates *TemplateEngine,
	attachments *AttachmentProcessor,
	validator *EmailValidator,
	queue *EmailQueue,
	bounces *BounceHandler,
	appURL string,
) *EmailFacade {
	return &EmailFacade{
		smtp:        smtp,
		templates:   templates,
		attachments: attachments,
		validator:   validator,
		queue:       queue,
		bounces:     bounces,
		appURL:      appURL,
		defaultFrom: "noreply@company.com",
	}
}

func (f *EmailFacade) SendTemplatedEmail(ctx context.Context, opts TemplatedEmailOptions) (EmailResult, error) {
	// Validate.
	if err := f.validator.Validate(opts.To); err != nil {
		return EmailResult{}, fmt.Errorf("validate recipient %q: %w", opts.To, err)
	}

	// Check bounce status.
	bounced, err := f.bounces.IsBounced(ctx, opts.To)
	if err != nil {
		return EmailResult{}, fmt.Errorf("check bounce status: %w", err)
	}
	if bounced {
		return EmailResult{}, fmt.Errorf("%w: %s", ErrBouncedEmail, opts.To)
	}

	// Render template.
	html, err := f.templates.Render(ctx, opts.Template, opts.Data)
	if err != nil {
		return EmailResult{}, fmt.Errorf("render template %q: %w", opts.Template, err)
	}

	// Process attachments.
	var attachments []ProcessedAttachment
	if len(opts.Attachments) > 0 {
		attachments, err = f.attachments.Process(ctx, opts.Attachments)
		if err != nil {
			return EmailResult{}, fmt.Errorf("process attachments: %w", err)
		}
	}

	from := opts.From
	if from == "" {
		from = f.defaultFrom
	}
	priority := opts.Priority
	if priority == "" {
		priority = "normal"
	}

	// Queue for sending.
	emailID, err := f.queue.Add(ctx, QueuedEmail{
		To:          opts.To,
		From:        from,
		Subject:     opts.Subject,
		HTML:        html,
		Attachments: attachments,
		Priority:    priority,
	})
	if err != nil {
		return EmailResult{}, fmt.Errorf("queue email: %w", err)
	}

	return EmailResult{EmailID: emailID, Status: "queued"}, nil
}

func (f *EmailFacade) SendSimpleEmail(ctx context.Context, to, subject, body string) (EmailResult, error) {
	return f.SendTemplatedEmail(ctx, TemplatedEmailOptions{
		To:       to,
		Subject:  subject,
		Template: "simple",
		Data:     map[string]any{"body": body},
	})
}

func (f *EmailFacade) SendWelcomeEmail(ctx context.Context, user User) (EmailResult, error) {
	return f.SendTemplatedEmail(ctx, TemplatedEmailOptions{
		To:       user.Email,
		Subject:  "Welcome!",
		Template: "welcome",
		Data:     map[string]any{"name": user.Name, "loginUrl": f.appURL + "/login"},
		Priority: "high",
	})
}

func (f *EmailFacade) SendPasswordResetEmail(ctx context.Context, user User, token string) (EmailResult, error) {
	resetURL := f.appURL + "/reset-password?token=" + url.QueryEscape(token)
	return f.SendTemplatedEmail(ctx, TemplatedEmailOptions{
		To:       user.Email,
		Subject:  "Reset Your Password",
		Template: "password-reset",
		Data:     map[string]any{"name": user.Name, "resetUrl": resetURL},
		Priority: "high",
	})
}

// Usage — simple and clear:
//
//	facade := NewEmailFacade(/* ... */)
//	facade.SendWelcomeEmail(ctx, newUser)
//	facade.SendPasswordResetEmail(ctx, user, resetToken)
```

### File Storage Facade

```go
package storage

import (
	"context"
	"crypto/md5"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Complex cloud storage subsystems (fields omitted).
type (
	S3Client             struct{}
	CloudFrontManager    struct{}
	ImageProcessor       struct{}
	VideoTranscoder      struct{}
	MetadataExtractor    struct{}
	AccessControlManager struct{}
)

// StorageFacade unifies file operations across the subsystems.
type StorageFacade struct {
	s3       *S3Client
	cdn      *CloudFrontManager
	images   *ImageProcessor
	videos   *VideoTranscoder
	metadata *MetadataExtractor
	acl      *AccessControlManager
}

func NewStorageFacade(
	s3 *S3Client,
	cdn *CloudFrontManager,
	images *ImageProcessor,
	videos *VideoTranscoder,
	metadata *MetadataExtractor,
	acl *AccessControlManager,
) *StorageFacade {
	return &StorageFacade{s3: s3, cdn: cdn, images: images, videos: videos, metadata: metadata, acl: acl}
}

func (f *StorageFacade) UploadFile(ctx context.Context, file []byte, opts UploadOptions) (UploadResult, error) {
	// Extract metadata.
	meta, err := f.metadata.Extract(ctx, file, opts.MIMEType)
	if err != nil {
		return UploadResult{}, fmt.Errorf("extract metadata: %w", err)
	}

	// Generate a unique key.
	key := f.generateKey(opts.Filename, meta)

	// Process based on type.
	processed := file
	if isImage(opts.MIMEType) {
		processed, err = f.images.Optimize(ctx, file, opts.ImageOptions)
		if err != nil {
			return UploadResult{}, fmt.Errorf("optimize image: %w", err)
		}
	}

	// Upload to S3.
	if err := f.s3.Upload(ctx, S3Object{
		Key:         key,
		Body:        processed,
		ContentType: opts.MIMEType,
		Metadata:    meta,
	}); err != nil {
		return UploadResult{}, fmt.Errorf("upload to s3: %w", err)
	}

	// Set access control.
	visibility := opts.Visibility
	if visibility == "" {
		visibility = "private"
	}
	if err := f.acl.SetPermissions(ctx, key, visibility); err != nil {
		return UploadResult{}, fmt.Errorf("set permissions: %w", err)
	}

	// Generate a CDN URL if public, otherwise a signed URL.
	var location string
	if visibility == "public" {
		location, err = f.cdn.URL(ctx, key)
	} else {
		expiry := opts.URLExpiry
		if expiry == 0 {
			expiry = time.Hour
		}
		location, err = f.s3.SignedURL(ctx, key, expiry)
	}
	if err != nil {
		return UploadResult{}, fmt.Errorf("build url: %w", err)
	}

	return UploadResult{Key: key, URL: location, Metadata: meta}, nil
}

func (f *StorageFacade) UploadImage(ctx context.Context, file []byte, opts ImageUploadOptions) (ImageUploadResult, error) {
	// Generate thumbnails.
	thumbnails, err := f.images.GenerateThumbnails(ctx, file, []ThumbnailSpec{
		{Width: 100, Height: 100, Suffix: "thumb"},
		{Width: 400, Height: 400, Suffix: "medium"},
		{Width: 800, Height: 800, Suffix: "large"},
	})
	if err != nil {
		return ImageUploadResult{}, fmt.Errorf("generate thumbnails: %w", err)
	}

	// Upload the original and every version.
	original, err := f.UploadFile(ctx, file, opts.UploadOptions)
	if err != nil {
		return ImageUploadResult{}, fmt.Errorf("upload original: %w", err)
	}

	result := ImageUploadResult{Original: original, Thumbnails: make(map[string]UploadResult, len(thumbnails))}
	for _, thumb := range thumbnails {
		thumbOpts := opts
		thumbOpts.Filename = opts.Filename + "-" + thumb.Suffix
		uploaded, err := f.UploadFile(ctx, thumb.Data, thumbOpts.UploadOptions)
		if err != nil {
			return ImageUploadResult{}, fmt.Errorf("upload thumbnail %s: %w", thumb.Suffix, err)
		}
		result.Thumbnails[thumb.Suffix] = uploaded
	}
	return result, nil
}

func (f *StorageFacade) UploadVideo(ctx context.Context, file []byte, opts VideoUploadOptions) (VideoUploadResult, error) {
	// Upload the original.
	original, err := f.UploadFile(ctx, file, opts.UploadOptions)
	if err != nil {
		return VideoUploadResult{}, fmt.Errorf("upload original: %w", err)
	}

	formats := opts.Formats
	if len(formats) == 0 {
		formats = []string{"720p", "480p", "360p"}
	}

	// Start the transcoding job asynchronously.
	job, err := f.videos.StartJob(ctx, TranscodeJob{
		SourceKey: original.Key,
		Formats:   formats,
		Thumbnail: true,
	})
	if err != nil {
		return VideoUploadResult{}, fmt.Errorf("start transcoding: %w", err)
	}

	return VideoUploadResult{
		Original:         original,
		TranscodingJobID: job.ID,
		Status:           "processing",
	}, nil
}

func (f *StorageFacade) DeleteFile(ctx context.Context, key string) error {
	// Delete from S3.
	if err := f.s3.Delete(ctx, key); err != nil {
		return fmt.Errorf("delete from s3: %w", err)
	}
	// Invalidate the CDN cache.
	if err := f.cdn.Invalidate(ctx, key); err != nil {
		return fmt.Errorf("invalidate cdn: %w", err)
	}
	return nil
}

func (f *StorageFacade) generateKey(filename string, meta Metadata) string {
	sum := md5.Sum([]byte(filename + strconv.FormatInt(time.Now().UnixNano(), 10)))
	return fmt.Sprintf("uploads/%s/%x/%s", meta.Type, sum, filename)
}

func isImage(mimeType string) bool {
	return strings.HasPrefix(mimeType, "image/")
}
```

### Authentication Facade

```go
package auth

import (
	"context"
	"errors"
	"fmt"
)

var (
	ErrInvalidCredentials = errors.New("invalid credentials")
	ErrInvalidMFACode     = errors.New("invalid MFA code")
)

type AuthFacade struct {
	users    UserRepository
	hasher   PasswordHasher
	tokens   TokenService
	sessions SessionManager
	mfa      MFAService
	audit    AuditLogger
	limiter  RateLimiter
}

func NewAuthFacade(
	users UserRepository,
	hasher PasswordHasher,
	tokens TokenService,
	sessions SessionManager,
	mfa MFAService,
	audit AuditLogger,
	limiter RateLimiter,
) *AuthFacade {
	return &AuthFacade{
		users:    users,
		hasher:   hasher,
		tokens:   tokens,
		sessions: sessions,
		mfa:      mfa,
		audit:    audit,
		limiter:  limiter,
	}
}

func (f *AuthFacade) Login(ctx context.Context, creds LoginCredentials) (LoginResult, error) {
	// Rate limiting.
	if err := f.limiter.Check(ctx, creds.Email); err != nil {
		return LoginResult{}, fmt.Errorf("rate limit: %w", err)
	}

	// Find user.
	user, err := f.users.FindByEmail(ctx, creds.Email)
	if err != nil {
		return LoginResult{}, fmt.Errorf("find user: %w", err)
	}
	if user == nil {
		f.audit.Log(ctx, "login_failed", map[string]any{"email": creds.Email, "reason": "user_not_found"})
		return LoginResult{}, ErrInvalidCredentials
	}

	// Verify password.
	if err := f.hasher.Verify(ctx, creds.Password, user.PasswordHash); err != nil {
		f.audit.Log(ctx, "login_failed", map[string]any{"userId": user.ID, "reason": "invalid_password"})
		return LoginResult{}, ErrInvalidCredentials
	}

	// Check MFA.
	if user.MFAEnabled {
		if creds.MFACode == "" {
			tempToken, err := f.tokens.CreateTempToken(ctx, user.ID)
			if err != nil {
				return LoginResult{}, fmt.Errorf("create temp token: %w", err)
			}
			return LoginResult{RequiresMFA: true, TempToken: tempToken}, nil
		}
		if err := f.mfa.Verify(ctx, user.ID, creds.MFACode); err != nil {
			return LoginResult{}, fmt.Errorf("verify mfa: %w", ErrInvalidMFACode)
		}
	}

	// Create session and tokens.
	session, err := f.sessions.Create(ctx, user.ID, creds.DeviceInfo)
	if err != nil {
		return LoginResult{}, fmt.Errorf("create session: %w", err)
	}
	tokens, err := f.tokens.CreateTokenPair(ctx, user.ID, session.ID)
	if err != nil {
		return LoginResult{}, fmt.Errorf("create tokens: %w", err)
	}

	f.audit.Log(ctx, "login_success", map[string]any{"userId": user.ID, "sessionId": session.ID})

	return LoginResult{
		User:         sanitizeUser(user),
		AccessToken:  tokens.AccessToken,
		RefreshToken: tokens.RefreshToken,
	}, nil
}

func (f *AuthFacade) Logout(ctx context.Context, accessToken string) error {
	payload, err := f.tokens.Verify(ctx, accessToken)
	if err != nil {
		return fmt.Errorf("verify token: %w", err)
	}
	if err := f.sessions.Invalidate(ctx, payload.SessionID); err != nil {
		return fmt.Errorf("invalidate session: %w", err)
	}
	if err := f.tokens.Blacklist(ctx, accessToken); err != nil {
		return fmt.Errorf("blacklist token: %w", err)
	}
	f.audit.Log(ctx, "logout", map[string]any{"userId": payload.UserID})
	return nil
}

func (f *AuthFacade) RefreshTokens(ctx context.Context, refreshToken string) (TokenPair, error) {
	pair, err := f.tokens.Refresh(ctx, refreshToken)
	if err != nil {
		return TokenPair{}, fmt.Errorf("refresh tokens: %w", err)
	}
	return pair, nil
}

func sanitizeUser(user *User) SafeUser {
	// Copy only the safe fields; password and MFA secret never leave the domain.
	return SafeUser{ID: user.ID, Email: user.Email, Name: user.Name}
}
```

## Facade vs Adapter

| Aspect | Facade | Adapter |
|--------|--------|---------|
| Purpose | Simplify complex subsystem | Make incompatible interfaces work |
| Scope | Entire subsystem | Single class/interface |
| Direction | New simple interface | Convert existing interface |
| Complexity | Reduces complexity | Maintains complexity |

## Benefits

| Benefit | Description |
|---------|-------------|
| Simplicity | Hides subsystem complexity |
| Decoupling | Clients don't depend on subsystems |
| Flexibility | Can change subsystems without affecting clients |
| Testability | Easy to mock facade for testing |
