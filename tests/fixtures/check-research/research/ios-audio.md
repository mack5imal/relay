# Research: ios-audio

## Question

What must happen before Safari on iOS will start microphone capture?

## Answer

A user gesture must resume the AudioContext, and getUserMedia prompts on first use only.
The app needs a tap-to-start step; auto-starting capture on load fails silently.

## Findings

- AudioContext starts suspended until a user gesture — https://developer.apple.com/documentation/webkit (Safari 17)

## Implications for this plan

- Add a "Tap to start" state to the live screen before capture begins.

## Confidence

medium — documented, but behaviour varies by iOS version.

Contradicts: S13 — "capture starts on launch" cannot hold on iOS
