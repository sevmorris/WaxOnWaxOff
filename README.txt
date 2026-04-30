IMPORTANT — Read Before First Launch
=====================================

macOS will block this app because it is not notarized with Apple.

After dragging WaxOn/WaxOff to Applications, open Terminal and run:

    xattr -cr /Applications/WaxOnWaxOff.app

Without this step, macOS will refuse to open the app.


ABOUT
=====================================

WaxOn/WaxOff is a two-mode podcast audio tool for macOS.

WaxOn — Raw Recording Prep
  Prepares raw recordings for editing. High-pass filtering, optional
  RNNoise denoise, optional de-esser, optional level riding and
  dynamic leveling, two-pass EBU R128 loudness normalization, phase
  rotation, and 2x oversampled brick-wall limiting. Outputs 24-bit WAV.

WaxOff — Delivery & Mastering
  Finalizes your edited mix for distribution. Two-pass EBU R128 loudness
  normalization, optional 150 Hz phase rotation, optional gentle
  pre-norm dynamic leveling, true peak control. WAV and/or CBR MP3
  output (up to 192 kbps).

Manual: https://sevmorris.github.io/WaxOnWaxOff/manual/
