# Research: pitch-detection

## Question

McLeod vs YIN accuracy on sung vocals in a browser AudioWorklet

## Answer

McLeod (MPM) matches YIN's accuracy on monophonic voice at lower cost, and handles vibrato
without octave errors when the clarity threshold is tuned. Use MPM with a 2048-sample window.

## Findings

- MPM's normalized square difference avoids YIN's octave errors on vibrato — https://www.cs.otago.ac.nz/research/publications/oucs-2008-03.pdf (2005 paper)
- A 2048-sample window at 48 kHz resolves down to E2 — https://example.org/pitchy/README (pitchy 4.1)
- AudioWorklet render quantum is 128 frames — unverified (training knowledge)

## Implications for this plan

- Phase 2 implements MPM, not YIN; the accuracy harness compares both on the synthetic set.
- S3's 80 ms budget holds with a 2048/512 window/hop.

## Confidence

high — two primary sources agree; one detail unverified.

Contradicts: none
