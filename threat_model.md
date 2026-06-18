# AudioGuard — Threat Model
**Version:** 1.0  
**Date:** 2026-06-10  
**Author:** Vidisha  
**Project:** AudioGuard IP Core — Hardware Security Module  
**Reference:** Guri, Solewicz, Daidakulov, Elovici — *MOSQUITO: Covert Ultrasonic Transmissions between Two Air-Gapped Computers using Speaker-to-Speaker Communication*, IEEE DSC 2018. [arXiv:1803.03422](https://arxiv.org/abs/1803.03422)

---

## 1. Purpose of This Document

This document defines the threat that AudioGuard is designed to detect and neutralize. It answers three questions before any RTL is written:

1. What exactly is the attack?
2. What does it look like at the hardware/signal level?
3. What does "success" mean for our defense?

Every design decision in the DSM, RoT, and Sanitizer modules traces back to a claim in this document.

---

## 2. The Attack: Acoustic Covert Channel via Ultrasonic Modulation

### 2.1 Core Mechanism (from MOSQUITO)

The MOSQUITO paper (Guri et al., 2018) demonstrates that malware can exploit a hardware feature called **jack retasking** — present in most Realtek and similar audio chipsets — to programmatically repurpose an audio output jack as an input jack at runtime, without any physical modification.

This means:
- A passive speaker, headphone, or earbud connected to the output jack is silently converted into a microphone.
- The audio chipset's DSP filter coefficients are tampered to allow the encoding of data into the **near-ultrasonic frequency range (18kHz–24kHz)**.
- The tampered audio stream plays normally to human ears (humans cannot hear above ~20kHz) but carries encoded binary data readable by a nearby sensor or a second compromised device.

### 2.2 Adaptation to AudioGuard's Threat Model

MOSQUITO targets air-gapped computers. AudioGuard adapts this to a more targeted scenario: **a music-processing chip inside a concert/venue audio system or consumer audio SoC.**

**Attack scenario:**

```
Attacker compromises audio DSP firmware
        │
        ▼
Tampers filter coefficients at runtime
        │
        ▼
Injects ultrasonic carrier (18–24kHz) into audio stream
        │
        ▼
Encodes data (keys, audio fingerprints, identifiers)
as B-FSK modulated signal above 20kHz
        │
        ▼
Audio plays normally to audience (Sunflower sounds fine)
        │
        ▼
Nearby sensor / second device receives and decodes leak
```

The human-audible signal (60Hz–16kHz music content) is fully preserved. The attack rides *on top of* the legitimate audio, invisible to listeners but readable by sensors.

### 2.3 Modulation Scheme (from MOSQUITO Section V.C)

The paper implements **Binary Frequency-Shift Keying (B-FSK)**:
- Bit `0` → frequency f₀ (e.g., 18kHz)
- Bit `1` → frequency f₁ (e.g., 22kHz)
- Packet structure: 6-bit preamble + 32-bit payload + 8-bit CRC = 46 bits per frame

This is the exact signal structure the AudioGuard Sanitizer targets. Any energy in the 18–24kHz band with structured periodicity is treated as a covert channel carrier.

---

## 3. Assets Being Protected

| Asset | Description | Why It Matters |
|---|---|---|
| Filter coefficient integrity | The FIR/IIR tap values loaded into the audio DSP | Tampered coefficients are the root cause of the attack |
| Audio output signal | The DAC output stream going to speakers | Carries the covert channel if not sanitized |
| Switching activity baseline | Expected toggle rates on audio-path nets | Anomalous switching = tampered filter behavior |
| Boot-time configuration | Filter state at power-on | Must be verified before audio path is enabled |

---

## 4. Adversary Model

| Property | Value |
|---|---|
| Adversary type | Compromised firmware / malicious DSP driver |
| Required access | Write access to audio filter coefficient registers |
| Required hardware | No additional hardware — exploits existing audio chipset |
| Detection evasion | Operates above human hearing; no visible artifact |
| Target | Audio processing chip in SoC, embedded audio system, or music venue hardware |
| Goal | Exfiltrate data (identifiers, keys, fingerprints) via ultrasonic carrier |

**What the adversary does NOT need:**
- Physical access to the chip
- A microphone (MOSQUITO proved speaker-to-speaker works)
- User interaction

**What the adversary cannot survive:**
- Filter coefficient hash mismatch detected at boot (RoT blocks audio path)
- Runtime switching activity anomaly detected (DSM triggers Sanitizer)
- Ultrasonic band stripped by hardware LPF (Sanitizer removes carrier)

---

## 5. Trust Boundary Definition

```
┌─────────────────────────────────────────────────────────────┐
│                    TRUSTED PERIMETER                        │
│                                                             │
│   ┌──────────┐    ┌──────────┐    ┌───────────────────┐    │
│   │  Audio   │───▶│  Filter  │───▶│  AudioGuard HSM   │    │
│   │   ADC    │    │  Bank    │    │  (DSM + RoT +     │    │
│   └──────────┘    │ (FIR/IIR)│    │   Sanitizer)      │    │
│                   └──────────┘    └─────────┬─────────┘    │
│                        ▲                    │              │
│                        │ ← ATTACK SURFACE   │              │
│                   Coefficient               ▼              │
│                   Registers            Clean DAC           │
│                   (tamper              Output              │
│                    target)                                  │
└─────────────────────────────────────────────────────────────┘

OUTSIDE PERIMETER:
  - Firmware / driver layer (untrusted after compromise)
  - Software coefficient loading (untrusted)
  - Any signal above 20kHz on the output (treated as suspect)
```

**Inside the perimeter (trusted):**
- The AudioGuard HSM module itself
- The golden key register (OTP, read-only after power-on)
- The hardware LPF output

**Outside the perimeter (untrusted after boot):**
- Filter coefficient registers (verified at boot, monitored at runtime)
- Any software-driven configuration
- The raw output of the audio filter bank before Sanitizer

---

## 6. Attack Surface Analysis

### 6.1 Primary Attack Surface: Filter Coefficients

The audio filter tap values determine which frequencies pass and at what gain. A tampered coefficient set can:
- Open a passband above 20kHz (normally blocked)
- Create a resonance at a specific ultrasonic frequency
- Introduce periodic modulation that encodes data

**Countermeasure:** RoT hashes coefficients at boot. DSM monitors switching activity at runtime as a behavioral proxy for coefficient state.

### 6.2 Secondary Attack Surface: Jack Retasking Register

As documented in MOSQUITO, Realtek audio chipsets expose a jack retasking register accessible in software. In our SoC model, the equivalent is the audio port direction control register.

**Countermeasure:** This register is part of the boot attestation check. Any change post-boot triggers the tamper latch.

### 6.3 Tertiary Attack Surface: Output Signal Itself

Even if detection fails, the ultrasonic carrier is present in the output signal.

**Countermeasure:** Hardware FIR LPF at 20kHz cutoff — strips the carrier unconditionally, independent of detection status.

---

## 7. Key Technical Parameters (derived from MOSQUITO)

| Parameter | Value | Source |
|---|---|---|
| Covert carrier frequency range | 18kHz – 24kHz | MOSQUITO Section V.B |
| Modulation scheme | B-FSK | MOSQUITO Section V.C |
| Packet size | 46 bits (6 preamble + 32 payload + 8 CRC) | MOSQUITO Section V.D |
| Maximum effective range | 9 meters (speaker-to-speaker) | MOSQUITO Section VI |
| Near-ultrasonic threshold | 18kHz (practically inaudible for adults) | MOSQUITO Section V.B |
| AudioGuard LPF cutoff | 20kHz | Design decision (conservative) |
| Warmth band to preserve | 400Hz – 8kHz | Design decision (vocal + instrument range) |

---

## 8. Definition of "Authorized" vs "Unauthorized" Modulation

This is the System Security Policy (SSP) core:

| Signal Characteristic | Authorized | Unauthorized |
|---|---|---|
| Frequency content | 20Hz – 20kHz | Any energy above 20kHz |
| Filter coefficient hash | Matches golden key in OTP register | Any deviation from golden key |
| Switching activity rate on audio nets | Within ±15% of golden baseline | Exceeds baseline by >15% |
| Jack direction register | Output-only at runtime | Any input retasking post-boot |
| Boot attestation result | PASS | FAIL → audio path disabled |

---

## 9. What "Success" Means for AudioGuard

The defense succeeds if:

1. **Detection:** The DSM identifies anomalous switching activity consistent with a tampered filter within one audio frame period.
2. **Attestation:** The RoT blocks the audio path if coefficient hash mismatches at boot, before any signal reaches the DAC.
3. **Sanitization:** The Sanitizer strips all energy above 20kHz from the output, regardless of detection status, with less than 5% energy loss in the 400Hz–8kHz band.
4. **Preservation:** The audible audio (concert/music output) continues without interruption — the sanitizer attenuates, never mutes.

**The attack is neutralized when:** an attacker cannot place a detectable signal above 20kHz on the output DAC, even with full compromise of the filter coefficient registers.

---

## 10. What This Document Does NOT Cover

- Software-layer defenses (OS-level jack retasking guards) — out of scope for an IP Core
- RF or electromagnetic side-channels — separate threat class
- Physical tampering of the chip — out of threat model for this version
- Attacks below 18kHz — audible to humans, detectable by listeners, out of scope

---

## 11. References

1. Guri, M., Solewicz, Y., Daidakulov, A., Elovici, Y. (2018). *MOSQUITO: Covert Ultrasonic Transmissions between Two Air-Gapped Computers using Speaker-to-Speaker Communication.* IEEE Conference on Dependable and Secure Computing (DSC 2018). arXiv:1803.03422
2. Guri, M., Solewicz, Y., Elovici, Y. (2020). *Speaker-to-Speaker Covert Ultrasonic Communication.* Journal of Information Security and Applications (JISA), 51.
3. NIST SP 800-193 — *Platform Firmware Resiliency Guidelines* (for RoT design reference)

---

*Next document: `docs/block_diagram.md` + exported `diagrams/block_diagram.png`*  
*Next RTL file: `rtl/dsm.v` — skeleton with port declarations*
