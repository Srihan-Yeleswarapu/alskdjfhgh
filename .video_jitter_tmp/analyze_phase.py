"""Clean zoom/pan jitter measurement via phase correlation.

phase correlation on a street-grid ROI is dominated by the static map
tiles, not the animated route/puck overlays. Log-polar phase correlation
gives per-frame scale (zoom); linear phase correlation gives pan.
"""
import cv2
import numpy as np

VIDEO = r"C:\Users\madhu\Downloads\WhatsApp Video 2026-09-05 at 6.01.57 PM.mp4"

cap = cv2.VideoCapture(VIDEO)
fps = cap.get(cv2.CAP_PROP_FPS)
W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

# Sub-ROI: left-center street grid — below "Sun Lakes" label, left of the
# cyan route, above "S ARIZONA AVE". Contains only static map tiles.
x0, x1 = 30, 220
y0, y1 = 560, 780
roi_w, roi_h = x1 - x0, y1 - y0

win = cv2.createHanningWindow((roi_w, roi_h), cv2.CV_32F)

def prep(img):
    roi = img[y0:y1, x0:x1]
    g = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    g = cv2.GaussianBlur(g, (3, 3), 0)
    return g.astype(np.float32)

# Log-polar params: center of ROI, maxRadius = half diagonal
cx, cy = roi_w / 2, roi_h / 2
maxR = min(cx, cy) * 0.9

def logpolar(g):
    return cv2.warpPolar(g, (roi_w, roi_h), (cx, cy), maxR,
                         cv2.INTER_LINEAR + cv2.WARP_POLAR_LOG)

ret, prev = cap.read()
if not ret:
    raise SystemExit("no frames")
prev_g = prep(prev)
prev_lp = logpolar(prev_g)

zs, dxs, dys, resp_lp, resp_lin, ts = [], [], [], [], [], []
n = 0
while True:
    ret, frame = cap.read()
    if not ret:
        break
    n += 1
    g = prep(frame)
    lp = logpolar(g)

    (sh_lp, r_lp) = cv2.phaseCorrelate(prev_lp, lp, win)
    (sh, r_lin) = cv2.phaseCorrelate(prev_g, g, win)

    # log-polar y-shift = log(scale); x-shift of polar = rotation (deg per px)
    dz = np.exp(sh_lp[1])          # scale factor vs previous frame
    zs.append(dz)
    dxs.append(sh[0])
    dys.append(sh[1])
    resp_lp.append(r_lp)
    resp_lin.append(r_lin)
    ts.append(n / fps)

    prev_g, prev_lp = g, lp

cap.release()
zs = np.array(zs); ts = np.array(ts)
scale_cum = np.cumprod(zs)
print(f"frames: {len(zs)}  ({ts[-1]:.2f}s @ {fps:.0f}fps)")
print(f"lp response mean {np.mean(resp_lp):.2f} | lin response mean {np.mean(resp_lin):.2f}")
print(f"cumulative zoom drift: {(scale_cum[-1] - 1) * 100:+.2f}%")
dzp = (zs - 1) * 100
print(f"frame-to-frame zoom step %: mean|.| {np.abs(dzp).mean():.4f}  p95 {np.percentile(np.abs(dzp),95):.4f}  max {np.abs(dzp).max():.4f}")

sign = np.sign(dzp)[np.abs(dzp) > 0.005]
flips = int(np.sum(sign[1:] * sign[:-1] < 0))
print(f"zoom direction reversals: {flips} in {ts[-1]:.1f}s ({flips/ts[-1]:.1f}/s)")

# Dominant period from cumulative-zoom autocorrelation (detrended)
k = int(fps)
pad = np.convolve(scale_cum, np.ones(k)/k, mode="same")
det = scale_cum - pad
det -= det.mean()
ac = np.correlate(det, det, "full")[len(det)-1:]
if ac[0] > 0:
    ac /= ac[0]
    lag_min = int(0.15 * fps)
    seg = ac[lag_min:int(3 * fps)]
    peak = lag_min + int(np.argmax(seg))
    print(f"dominant oscillation period: {peak/fps:.3f}s (r={ac[peak]:.2f})")

# Pan stats
dxs = np.array(dxs); dys = np.array(dys)
print(f"pan px/frame: |dx| mean {np.abs(dxs).mean():.3f} p95 {np.percentile(np.abs(dxs),95):.3f}; "
      f"|dy| mean {np.abs(dys).mean():.3f} p95 {np.percentile(np.abs(dys),95):.3f}")

np.save(".video_jitter_tmp/zs.npy", zs)
np.save(".video_jitter_tmp/t2.npy", ts)
np.save(".video_jitter_tmp/scale_cum.npy", scale_cum)
