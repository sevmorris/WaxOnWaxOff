# Theory of Operation — Research Audit & Proposal

**Source file:** `docs/manual/theory.html`  
**Audit date:** May 2026  
**Scope:** Verify technical and historical claims against primary sources; identify gaps; produce prioritized, citation-backed edit proposals. `theory.html` is NOT modified by this document.

---

## Executive Summary

The document is technically sound overall. Most claims are correct and well-reasoned. However, the audit found:

- **3 factual errors** (incorrect dates or specs that readers would trust and act on)
- **1 questionable claim** (defensible but misleading for the primary audience)
- **4 unsourced assertions** that are likely correct but have no citation and could be challenged
- **5 gaps** worth filling — missing context that would make the document more useful

All findings are prioritized. P1 items are factual errors that should be corrected. P2 items are citation gaps. P3 items are optional improvements.

---

## P1: Factual Errors

### P1-A — Spotify loudness normalization date is wrong

**Location:** EBU R128 → History & Context callout, paragraph 3  
**Current text:**  
> "Spotify formalized its −14 LUFS target in 2021"

**Finding: INCORRECT.**  
Spotify launched loudness normalization in **2014**. The default target was initially hotter (~−11 LUFS). Spotify moved to −14 LUFS as the standard "Normal" mode around **2017**, not 2021. No significant loudness policy change in 2021 is documented.

**Sources:**  
- Spotify support article: https://support.spotify.com/us/artists/article/loudness-normalization/  
- Sound On Sound "The End of the Loudness War?": https://www.soundonsound.com/techniques/end-loudness-war

**Proposed fix:**  
> "Spotify began loudness normalization at launch in 2014, standardizing its −14 LUFS target around 2017"

---

### P1-B — Apple Podcasts mono loudness target is wrong

**Location:** WaxOff Design → Delivery Targets table  
**Current text:**  
> (History & Context callout, paragraph 3): "Apple Podcasts specifies −16 LKFS for stereo and −19 LKFS for mono"
>
> (Delivery table): Apple Podcasts: −16 LUFS (normalized)

**Finding: INCORRECT.**  
Apple Podcasts' official specification states a single target of **−16 dB LKFS** with ±1 dB tolerance, for all content. There is no mono-specific −19 LKFS requirement in Apple's documentation. The Apple Podcasts for Creators support page (https://podcasters.apple.com/support/893-audio-requirements) says: "we recommend that the audio signals are preconditioned so the overall loudness remains around -16 dB LKFS."

The −19 LUFS for mono figure comes from **Buzzsprout's own internal target** (their Magic Mastering tool targets −19 LUFS for mono submissions and −16 LUFS for stereo), not from Apple. Several third-party guides conflate this with Apple's spec.

**Sources:**  
- Apple Podcasts for Creators: https://podcasters.apple.com/support/893-audio-requirements  
- Buzzsprout Magic Mastering FAQs: https://www.buzzsprout.com/help/224-magic-mastering-faqs

**Proposed fix in the callout:**  
Remove the stereo/mono distinction for Apple. Correct text: "Apple Podcasts specifies −16 LKFS with a ±1 dB tolerance."

**Proposed fix in the delivery table:**  
Apple Podcasts row is fine as-is (shows −16 LUFS). The callout claim with the mono/stereo distinction should be removed or corrected.

---

### P1-C — RNNoise paper venue is wrong

**Location:** RNNoise → History & Context callout  
**Current text:**  
> "The original paper, *A Hybrid DSP/Deep Learning Approach to Real-Time Full-Band Speech Enhancement*, was presented at ITRW on Speech Communication in 2018."

**Finding: INCORRECT.**  
The paper was presented at the **IEEE Multimedia Signal Processing (MMSP) Workshop, 2018**. The arXiv preprint (arXiv:1709.08243) appeared September 2017. There is no ITRW on Speech Communication edition in 2018 that includes this paper; the venue is wrong.

**Sources:**  
- arXiv: https://arxiv.org/abs/1709.08243  
- Semantic Scholar: https://www.semanticscholar.org/paper/A-Hybrid-DSP-Deep-Learning-Approach-to-Real-Time-Valin/782526e9a256a6d9a1582648212b53740107df38

**Proposed fix:**  
> "The original paper, *A Hybrid DSP/Deep Learning Approach to Real-Time Full-Band Speech Enhancement* (arXiv:1709.08243), was presented at the IEEE Multimedia Signal Processing Workshop in 2018 and has since been widely cited in the speech enhancement literature."

---

## P1-D — Lipshitz et al. papers started in 1984, not "the late 1980s"

**Location:** Dithering → The Mathematical Fix: TPDF Dither  
**Current text:**  
> "The mathematical foundation was established by Stanley Lipshitz, Robert Wannamaker, and John Vanderkooy at the University of Waterloo in a series of papers beginning in the **late 1980s**."

**Finding: INCORRECT (date).**  
The foundational work began in **1984**, not the late 1980s. Vanderkooy and Lipshitz published "Resolution Below the Least Significant Bit in Digital Systems with Dither" in the AES Journal in **1984** (Vol. 32, No. 3). A second paper appeared in 1987. Wannamaker's formal theoretical contribution came in the 1990s ("A Theory of Non-Subtractive Dither," IEEE Trans. 2000), but the core AES dithering papers are 1984/1987. "Beginning in the late 1980s" understates how early this work appeared.

**Sources:**  
- AES e-Library: "Dither in Digital Audio" (1984): https://www.aes.org/e-lib/browse.cfm?elib=11586  
- AES e-Library: "Resolution Below the Least Significant Bit..." (1984): https://www.aes.org/e-lib/browse.cfm?elib=4523

**Proposed fix:**  
> "The mathematical foundation was established by Stanley Lipshitz, Robert Wannamaker, and John Vanderkooy at the University of Waterloo in a series of papers beginning in **1984**."

---

## P2: Needs Citation (Claims That Are Likely Correct But Unsourced)

### P2-A — Specific MP3 true peak increase figures lack a source

**Location:** True Peak → History & Context callout "The Streaming Ingest Trap"  
**Current text:**  
> "Research measuring 128 kbps MP3 encoding has documented decoded true peaks rising by +1.7 dBTP above the source, and pathological cases as high as +10 dBTP."

**Finding: UNVERIFIED specific figures.**  
That MP3/AAC encoding raises true peaks is well-documented (broadly confirmed by FabFilter, Spotify's own artist documentation, and audio engineering literature). The specific values of +1.7 dBTP and +10 dBTP appear to be sourced from the same research, but the original study is not named or linked. Without a citation, readers cannot evaluate the methodology or the "pathological case" claim.

**Proposed fix:** Either (a) name the source research (if it can be located), or (b) soften to the documented range: "Research has documented decoded true peaks rising by 1–3 dBTP above the source in typical cases, with extreme cases considerably higher." The Spotify artist documentation (https://support.spotify.com/us/artists/article/loudness-normalization/) states that masters at +1–4 dBTP are "virtually guaranteed to cause encoder clipping," which provides an indirect lower bound. FabFilter's Pro-L documentation on true peak limiting (https://www.fabfilter.com/help/pro-l/using/truepeaklimiting) also notes typical codec-induced ISP increases.

---

### P2-B — Libsyn CBR recommendation is unsourced

**Location:** Output Formats → MP3 CBR  
**Current text:**  
> "Libsyn, one of the largest podcast hosting platforms, explicitly recommends CBR in their encoding documentation."

**Finding: UNSOURCED.**  
Libsyn is not mentioned anywhere in the Marco Arment VBR article (marco.org/2016/08/15/vbr-mp3-plea). The Libsyn encoding recommendation claim may be accurate but could not be verified. Libsyn's public-facing documentation is not easily findable via web search, and their help content may have changed since the claim was written.

**Proposed fix:** Either verify and link the specific Libsyn doc, or remove the Libsyn attribution and simply state: "Major podcast hosting platforms recommend CBR for compatibility, and many explicitly warn against VBR." The VBR-seeking problem is fully supported by the Marco Arment data alone.

---

### P2-C — Conversational speech inter-word gap (150–300 ms) needs citation

**Location:** True Peak → WaxOn Limiter Settings callout  
**Current text:**  
> "the typical gap between words in conversational speech is 150–300 ms"

**Finding: PLAUSIBLE but uncited.**  
This figure appears in speech processing literature but is not cited. A reference to phonetic/speech research would strengthen the claim. The actual range varies considerably by speaker, language, and speaking rate.

**Proposed fix:** Add parenthetical citation, e.g., "(inter-word pauses in English conversational speech typically range from 150–300 ms; Tsao et al., 2006)" or soften to "typically 100–400 ms depending on speaking rate."

---

### P2-D — Plosive consonant onset time (10–30 ms) needs citation

**Location:** True Peak → WaxOn Limiter Settings callout  
**Current text:**  
> "a typical plosive consonant (p, b, t) has an onset of 10–30 ms"

**Finding: PLAUSIBLE but uncited.**  
This is consistent with phonetics literature on voice onset time (VOT) but is stated without a source. A phonetics textbook reference would be appropriate here.

---

## P3: Optional Improvements and Gaps

### P3-A — The standard is now BS.1770-5 (2023)

**Location:** Throughout — K-weighting callout, true peak section  
**Current text:** References ITU-R BS.1770-4 as the active standard.

**Finding: OUTDATED.**  
ITU-R BS.1770-5 was published in **November 2023**. Apple Podcasts' own requirements page now references BS.1770-5 explicitly. The core K-weighting and gating algorithms are unchanged between -4 and -5; the main addition in -5 is an Annex 4 defining loudness measurement for object-based audio (Dolby Atmos, etc.), which is irrelevant to podcast workflows. However, the document should acknowledge that BS.1770-4 is no longer the current revision, even if the relevant algorithms are identical.

**Proposed fix:** In the K-weighting callout or intro paragraph, note: "The current revision is ITU-R BS.1770-5 (November 2023). BS.1770-5 adds an annex for object-based audio formats; the K-weighting and gating algorithms used for stereo/mono podcast content are unchanged from -4."

---

### P3-B — Proximity effect +20 dB figure overstates cardioid behavior

**Location:** Phase Rotation → How Allpass Filtering Reduces Crest Factor  
**Current text:**  
> "The boost can reach +20 dB at very close distances."

**Finding: MISLEADING for the audience.**  
The +20 dB proximity effect figure applies to **figure-8 (bidirectional) microphones** at extremely close distances (~5 cm). Cardioid microphones — which dominate podcast use, as the text correctly notes — typically exhibit **6–12 dB** of bass boost at close working distances. The text attributes the +20 dB figure to "directional microphones (cardioids, supercardioids, figure-8 patterns)" collectively, which is technically defensible but will likely cause podcast users with cardioid mics to overestimate the effect.

**Sources:**  
- DPA Microphones mic university on proximity effect: https://www.dpamicrophones.com/mic-university/background-knowledge/proximity-effect-in-microphones-explained/  
- Neumann knowledge base on proximity effect: https://www.neumann.com/en-us/knowledge-base/neumann-im-homestudio/homestudio-academy/what-is-the-proximity-effect

**Proposed fix:**  
> "The boost can reach 6–12 dB at typical podcast working distances for cardioids, and up to 20 dB for figure-8 patterns at extremely close range."

---

### P3-C — Buzzsprout delivery table entry is incomplete

**Location:** WaxOff Design → Delivery Targets table  
**Current text:**  
> Buzzsprout | −19 LUFS recommended | −1.0 dBTP

**Finding: INCOMPLETE.**  
Buzzsprout targets **−19 LUFS for mono** and **−16 LUFS for stereo**. The table shows only −19 LUFS without the channel-count distinction, which could mislead stereo podcast producers.

**Source:** https://www.buzzsprout.com/help/224-magic-mastering-faqs

**Proposed fix:**  
> Buzzsprout | −19 LUFS (mono) / −16 LUFS (stereo) | −1.0 dBTP

---

### P3-D — Speech crest factor range could be refined

**Location:** Phase Rotation → Crest Factor  
**Current text:**  
> "Typical speech has a crest factor of 15–25 dB."

**Finding: SLIGHTLY BROAD.**  
Speech processing literature typically cites 20–23 dB for the peak-to-RMS ratio of speech signals. The lower bound of 15 dB would represent heavily compressed or processed speech. For unprocessed podcast recordings, 18–25 dB is more accurate. The current range is not wrong, but 20–23 dB would be more defensible.

**Source:** ProSoundWeb on crest factor: https://www.prosoundweb.com/understanding-the-nuances-of-crest-factor/

**Proposed fix:**  
> "Typical unprocessed speech has a crest factor of 18–25 dB, with 20–23 dB most commonly cited in speech processing literature."

---

### P3-E — RNNoise conference venue should be noted correctly alongside paper year

**Already captured as P1-C.** The fix there covers this gap.

---

### P3-F — YouTube normalization year (2015–2016) could be tightened

**Location:** EBU R128 → History & Context callout, paragraph 3  
**Current text:**  
> "YouTube introduced normalization in 2015–2016"

**Finding: APPROXIMATELY CORRECT.**  
The rollout began in December 2015 and applied broadly to existing content by August 2016, after which new uploads were normalized on ingest. The current text's "2015–2016" range is accurate but could be more specific. This is low priority — the approximate date is fine.

---

## Anti-Recommendations (Do Not Add)

1. **Do not add a derivation of BS.1770-5's object-based audio annex.** It's irrelevant to stereo podcast work and would bloat the document.
2. **Do not add Spotify's user-selectable normalization modes (Loud/Normal/Quiet).** The Loud (−11 LUFS) and Quiet (−23 LUFS) options are playback preferences, not delivery specs. Adding them would confuse the delivery guidance.
3. **Do not add a full TPDF variance derivation.** The current explanation (variance = 1/6 LSB², non-subtractive form achieves decorrelation) is the right level of depth for this document. A formal proof would only serve DSP researchers and is already covered in the Lipshitz/Vanderkooy papers.
4. **Do not add per-loudness-meter UI comparisons** (iZotope Insight, HOFA, Youlean, etc.). This is an algorithm document, not a tool survey.

---

## Summary Priority Table

| # | Location | Issue | Priority |
|---|----------|-------|----------|
| P1-A | History callout | Spotify −14 LUFS "formalized in 2021" → actually ~2017 | **P1 Fix** |
| P1-B | History callout + delivery table | Apple Podcasts −19 LKFS for mono is not Apple's spec | **P1 Fix** |
| P1-C | RNNoise callout | Paper venue is "ITRW on Speech Communication" → actually IEEE MMSP | **P1 Fix** |
| P1-D | Dithering section | Lipshitz papers "late 1980s" → first paper was 1984 | **P1 Fix** |
| P2-A | True Peak callout | +1.7 dBTP / +10 dBTP MP3 figures need a named source | P2 Citation |
| P2-B | MP3 CBR section | Libsyn CBR recommendation needs a verifiable source | P2 Citation |
| P2-C | Limiter callout | Inter-word gap 150–300 ms needs a speech research citation | P2 Citation |
| P2-D | Limiter callout | Plosive onset 10–30 ms needs a phonetics citation | P2 Citation |
| P3-A | K-weighting callout | Acknowledge BS.1770-5 (Nov 2023); note algorithms unchanged | P3 Gap |
| P3-B | Phase rotation | +20 dB proximity boost is for figure-8, not cardioids | P3 Gap |
| P3-C | Delivery table | Buzzsprout −19 LUFS is mono-only; stereo is −16 LUFS | P3 Gap |
| P3-D | Crest factor section | 15–25 dB range; literature centers on 20–23 dB for speech | P3 Gap |

---

*This document is a research proposal only. No edits to `theory.html` were made during this audit.*
