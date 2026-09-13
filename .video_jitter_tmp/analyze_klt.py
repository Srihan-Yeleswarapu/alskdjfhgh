"""Robust zoom-jitter measurement: KLT optical flow + RANSAC similarity.

Street-grid corner features dominate the map ROI; the animated route/puck
overlays contribute few features that RANSAC rejects as outliers. The
per-frame similarity scale (zoom) is then clean.
"""
import cv2
import numpy as np

VIDEO = r"C:\Users\madhu\Downloads\WhatsApp Video 2026-09-05 at 6.01.57 PM.mp4"

cap = cv2.VideoCapture(VIDEO)
fps = cap.get(cv2.CAP_PROP_FPS)
W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

# Map ROI excluding HUD chrome
x0, x1 = int(W * 0.06), int(W * 0.94)
y0, y1 = int(H * 0.30), int(H * 0.70)

lk = dict(winSize=(21, 21), maxLevel=3,
          criteria=(cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 30, 0.01))
feat = dict(maxCorners=400, qualityLevel=0.01, minDistance=6, blockSize=7)

def prep(img):
    roi = img[y0:y1, x0:x1]
    return cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)

ret, prev = cap.read()
if not ret:
    raise SystemExit("no frames")
prev_g = prep(prev)
p0 = cv2.goodFeaturesToTrack(prev_g, mask=None, **feat)

scales, txs, tys, inl_frac, ts = [], [], [], [], []
n = 0
while True:
    ret, frame = cap.read()
    if not ret:
        break
    n += 1
    g = prep(frame)
    p1, st, err = cv2.calcOpticalFlowPyrLK(prev_g, g, p0, None, **lk)
    if p1 is None or st.sum() < 30:
        p0 = cv2.goodFeaturesToTrack(g, mask=None, **feat)
        prev_g = g
        continue
    good = st.ravel() == 1
    a, b = p0[good], p1[good]
    M, inl = cv2.estimateAffinePartial2D(a, b, method=cv2.RANSAC,
                                         ransacReprojThreshold=1.0,
                                         maxIters=2000, confidence=0.999)
    if M is None:
        p0 = b.reshape(-1, 1, 2)
        prev_g = g
        continue
    s = np.sqrt(M[0, 0] ** 2 + M[1, 0] ** 2)
    scales.append(s)
    txs.append(M[0, 2])
    tys.append(M[1, 2])
    inl_frac.append(inl.sum() / len(inl))
    ts.append(n / fps)
    # re-seed features occasionally to avoid drift starvation
    if len(b) < 120:
        p0 = cv2.goodFeaturesToTrack(g, mask=None, **feat)
    else:
        p0 = b.reshape(-1, 1, 2)
    prev_g = g

cap.release()
scales = np.array(scales); ts = np.array(ts)
cum = np.cumprod(scales)
dzp = (scales - 1) * 100

print(f"frames: {len(scales)} ({ts[-1]:.2f}s)  mean inlier fraction {np.mean(inl_frac):.2f}")
print(f"cumulative zoom drift: {(cum[-1] - 1) * 100:+.3f}%")
print(f"per-frame zoom step %: mean|.| {np.abs(dzp).mean():.4f}  p95 {np.percentile(np.abs(dzp),95):.4f}  max {np.abs(dzp).max():.4f}")

sign = np.sign(dzp)[np.abs(dzp) > 0.003]
flips = int(np.sum(sign[1:] * sign[:-1] < 0))
print(f"zoom reversals: {flips} in {ts[-1]:.1f}s ({flips/ts[-1]:.1f}/s)")

# dominant period of cumulative zoom (breathing)
k = int(fps)
if len(cum) > 3 * k:
    pad = np.convolve(cum, np.ones(k) / k, mode="same")
    det = cum - pad
    det -= det.mean()
    ac = np.correlate(det, det, "full")[len(det) - 1:]
    ac /= ac[0]
    lag_min = int(0.15 * fps)
    seg = ac[lag_min:int(3 * fps)]
    peak = lag_min + int(np.argmax(seg))
    print(f"dominant breathing period: {peak / fps:.3f}s (r={ac[peak]:.2f})")

txs = np.array(txs); tys = np.array(tys)
print(f"pan px/frame: |tx| mean {np.abs(txs).mean():.3f} p95 {np.percentile(np.abs(txs),95):.3f}; "
      f"|ty| mean {np.abs(tys).mean():.3f} p95 {np.percentile(np.abs(tys),95):.3f}")

# amplitude of the breathing: std of detrended cumulative zoom, in % of screen
pad = np.convolve(cum, np.ones(k) / k, mode="same")
det = cum - pad
print(f"breathing amplitude: +/-{det.std() * 100:.3f}% of map scale "
      f"(~{det.std() * (y1 - y0):.1f}px at ROI height {y1 - y0})")

np.save(".video_jitter_tmp/scales_r.npy", scales)
np.save(".video_jitter_tmp/t_r.npy", ts)
np.save(".video_jitter_tmp/cum_r.npy", cum)
