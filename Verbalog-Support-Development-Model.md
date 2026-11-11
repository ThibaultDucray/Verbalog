# Verbalog Support Development Model

## Overview

Verbalog is a free and open-source macOS application that turns audio recordings into structured meeting notes. Its core features remain available to everyone, without requiring an account, a subscription, or a licence key.

To help fund maintenance and future development, Verbalog may occasionally invite users to make a voluntary contribution through a **Support Development** option.

## Guiding Principle

A contribution is not a software purchase and does not unlock features. It is a voluntary way for users who find Verbalog useful to support its continued development.

This model is consistent with Verbalog's open-source nature:

- The application remains fully functional whether or not the user contributes.
- No account or sign-in is required.
- No personal information needs to be collected by Verbalog.
- No online licence validation is performed.
- Users can permanently dismiss contribution prompts.
- The source code remains available and can be inspected or modified.

Because a determined user could modify the open-source code or bypass any local supporter flag, Verbalog does not attempt to implement restrictive payment verification. Such controls would add complexity without meaningfully protecting revenue, since no paid functionality is being unlocked.

## Suggested User Experience

After the user has received meaningful value from Verbalog, for example after creating 10 meeting notes, the application may display a discreet prompt:

> **Enjoying Verbalog?**
>
> You have already turned 10 meetings into notes with Verbalog. The app is free and open source. If it saves you time, please consider supporting its continued development.
>
> **Support Development** · **Maybe Later**
>
> *Already supported, or prefer not to be asked again? Don't show this again.*

The prompt should never prevent access to the application or interrupt an active recording, transcription, or note-generation workflow.

### Available actions

- **Support Development** opens a Stripe-hosted payment page in the user's default browser.
- **Maybe Later** dismisses the prompt and postpones the next invitation, for example until 20 additional meeting notes have been created or at least 60 days have passed.
- **Don't Show This Again** permanently disables automatic support prompts on that Mac.

A permanent **Support Development…** item may remain available in the **Help** menu, even when automatic prompts have been disabled.

## Remembering a Supporter Without an Account

Verbalog does not need to verify that a payment has occurred. After returning from the payment page, or when the user selects **I've Already Supported**, the application can store a simple local supporter status.

The preferred implementation is the macOS Keychain because it may survive application updates and reinstalls more reliably than `UserDefaults`.

Example local values:

```text
supportStatus = supporter
supportDate = 2026-11-11
supportPromptsDisabled = true
```

A simpler implementation using `UserDefaults` is also acceptable if persistence across reinstalls is not important.

The **I've Already Supported** action is intentionally based on trust. If someone uses it without contributing, they only suppress a voluntary prompt; they do not gain access to restricted functionality. Verbalog therefore loses little by avoiding payment verification, while preserving a simple, private, and account-free experience.

## Payment Flow

The recommended flow is deliberately lightweight:

1. The user selects **Support Development** in Verbalog.
2. Verbalog opens a Stripe Payment Link in the default browser.
3. The user chooses or confirms a contribution amount and completes the payment on Stripe's website.
4. The user returns to Verbalog.
5. Verbalog records the local supporter status, either through an explicit **I've Already Supported** action or an optional callback URL.
6. Automatic support prompts are disabled.

If a callback such as `verbalog://support/success` is used, it should be treated as a convenience rather than proof of payment. A custom URL can be invoked manually and should not be considered a secure payment receipt.

## Privacy and Security Boundaries

- Verbalog should not embed Stripe secret keys in the macOS application.
- Payment entry and processing should remain on Stripe's hosted page.
- Verbalog does not need to receive the contributor's name, email address, card details, or transaction identifier.
- No backend, webhook, user database, or authentication service is required for this voluntary-support model.
- The supporter status should remain local to the user's Mac.

## Recommended Wording

### Help menu

Before support:

> ☕ Support Development…

After support:

> ❤️ Thanks for Supporting Verbalog
>
> Support Again…

### Website or About window

> **Local. Private. Open source. No account. Free to use.**
>
> Verbalog is independently developed. If it saves you time, you can support the project with a voluntary contribution.

## Product Positioning

This model reinforces Verbalog's intended positioning:

- local-first meeting transcription and note generation;
- privacy by design;
- no mandatory account;
- open-source and transparent;
- free access to core functionality;
- voluntary community support rather than a forced paywall.

If Verbalog later introduces services with genuine ongoing costs, such as cloud synchronisation, hosted AI processing, team workspaces, or managed storage, those services can use a separate paid plan with server-side entitlement checks. The voluntary **Support Development** model should remain distinct from any future commercial service.
