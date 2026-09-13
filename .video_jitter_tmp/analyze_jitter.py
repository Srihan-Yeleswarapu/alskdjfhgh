"""Quantify map zoom/pan/rotation jitter in a screen recording.

Computes a per-frame similarity transform (scale, rotation, translation)
between consecutive frames using OpenCV ECC alignment on a stable ROI
(the map area, excluding HUD chrome), then reports:
  - per-frame relative zoom (%) time series
  - dominant oscillation period (autocorrelation of the detrended series)
  - summary stats (mean |dz| per second, max excursion)
"""
import cv2
import numpy as np
import sys

VIDEO = r"C:\Users\madhu\Downloads\WhatsApp Video 2026-09-05 at 6.01.57 PM.mp4"

cap = cv2.VideoCapture(VIDEO)
fps = cap.get(cv2.CAP_PROP_FPS)
W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

# Map ROI: exclude top HUD/card chrome (~top 30%) and bottom HUD (~bottom 30%).
x0, x1 = int(W * 0.05), int(W * 0.95)
y0, y1 = int(H * 0.32), int(H * 0.68)

def prep(img):
    roi = img[y0:y1, x0:x1]
    roi = cv2.resize(roi, (0, 0), fx=0.5, fy=0.5, interpolation=cv2.INTER_AREA)
    g = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    g = cv2.GaussianBlur(g, (3, 3), 0)
    return g.astype(np.float32) / 255.0

STEP = 2   # analyze every 2nd frame (30 fps) — plenty for ~0.3-0.5s periods
ret, prev = cap.read()
if not ret:
    sys.exit("no frames")
prev_g = prep(prev)

warp3 = np.eye(3, dtype=np.float32)   # cumulative transform vs frame 0
last = np.eye(2, 3, dtype=np.float32)

scales, pans, rots, idx = [], [], [], []
i = 0
n = 0
criteria = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 30, 1e-6)

while True:
    ret, frame = cap.read()
    if not ret:
        break
    n += 1
    if n % STEP:
        continue
    i += 1
    g = prep(frame)
    try:
        cc, w = cv2.findTransformECC(prev_g, g, last, cv2.MOTION_AFFINE,
                                     criteria, None, 3)
        last = w.astype(np.float32)
        L = np.vstack([last, [0, 0, 1]])
        warp3 = warp3 @ L
        warp = warp3[:2]
        s = np.sqrt(np.abs(warp[0, 0] * warp[1, 1] - warp[0, 1] * warp[1, 0]))
        rot = np.degrees(np.arctan2(warp[1, 0], warp[0, 0]))
        pan = (warp[0, 2], warp[1, 2])
        scales.append(s)
        rots.append(rot)
        pans.append(pan)
        idx.append(n / fps)
        prev_g = g
    except cv2.error:
        pass

cap.release()
scales = np.array(scales)
t = np.array(idx)
dz = np.diff(scales) / scales[:-1] * 100.0   # frame-to-frame relative zoom %

print(f"frames analyzed: {len(scales)}  ({t[-1]:.2f}s @ {fps:.0f}fps)")
print(f"cumulative zoom drift: {(scales[-1] - 1) * 100:+.2f}%")
print(f"frame-to-frame |dz|: mean {np.abs(dz).mean():.3f}%  "
      f"p95 {np.percentile(np.abs(dz), 95):.3f}%  max {np.abs(dz).max():.3f}%")

# Detrend with a 1s moving average, then autocorrelation for the period.
k = max(3, int(fps))
pad = np.convolve(scales, np.ones(k) / k, mode="same")
det = scales - pad
det = det - det.mean()
ac = np.correlate(det, det, "full")[len(det)-1:]
ac /= ac[0] if ac[0] else 1
# First prominent peak beyond 0.25 s
lag_min = int(0.25 * fps)
peak = lag_min + int(np.argmax(ac[lag_min:int(2.5 * fps)]))
print(f"dominant oscillation period: {peak / fps:.2f}s  (autocorr r={ac[peak]:.2f})")

# Direction-reversal count (zoom in <-> out flips) per second
sign = np.sign(dz)
sign = sign[np.abs(dz) > 0.02]
flips = int(np.sum(sign[1:] * sign[:-1] < 0))
print(f"zoom direction reversals: {flips} in {t[-1]:.1f}s  "
      f"({flips / t[-1]:.1f}/s)")

# Per-second breakdown to locate the jitter window
print("\nper-second mean |dz|% and reversal count:")
for sec in range(int(t[-1])):
    m = (t[1:] >= sec) & (t[1:] < sec + 1)
    if m.any():
        s_dz = np.abs(dz[m])
        sg = np.sign(dz[m])[np.abs(dz[m]) > 0.02]
        fl = int(np.sum(sg[1:] * sg[:-1] < 0)) if len(sg) > 1 else 0
        print(f"  t={sec:2d}s  mean|dz|={s_dz.mean():.3f}%  max={s_dz.max():.3f}%  reversals={fl}")

np.save(".video_jitter_tmp/scales.npy", scales)
np.save(".video_jitter_tmp/t.npy", t)
