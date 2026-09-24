"""Generate Black-Scholes reference vectors for test/PricingEngine.t.sol.

Uses the exact normal CDF, N(x) = erfc(-x/sqrt(2))/2, from the standard library (identical to
scipy.stats.norm.cdf). Values are emitted as 1e18 fixed-point integer strings.

    python script/gen_vectors.py
"""
import json
import math
import pathlib

R = 0.05
YEAR = 365 * 24 * 3600
SCALE = 10**18


def ncdf(x: float) -> float:
    return 0.5 * math.erfc(-x / math.sqrt(2.0))


def bs_call(s, k, vol, t_years, r=R):
    d1 = (math.log(s / k) + (r + vol * vol / 2) * t_years) / (vol * math.sqrt(t_years))
    d2 = d1 - vol * math.sqrt(t_years)
    price = s * ncdf(d1) - k * math.exp(-r * t_years) * ncdf(d2)
    return price, ncdf(d1)


def fx(x: float) -> str:
    return str(int(round(x * SCALE)))


spots = [100.0, 2000.0]
moneyness = [0.7, 0.85, 0.95, 1.0, 1.05, 1.15, 1.3, 1.5]
vols = [0.2, 0.5, 0.8, 1.5, 2.5]
times = [3600, 86400, 7 * 86400, 30 * 86400, YEAR]

rows = []
for s in spots:
    for m in moneyness:
        for v in vols:
            for secs in times:
                k = s * m
                price, delta = bs_call(s, k, v, secs / YEAR)
                rows.append(
                    {
                        "spot": fx(s),
                        "strike": fx(k),
                        "vol": fx(v),
                        "secs": str(secs),
                        "price": fx(price),
                        "delta": fx(delta),
                    }
                )

out = {"rate": fx(R), "n": len(rows)}
for key in ["spot", "strike", "vol", "secs", "price", "delta"]:
    out[key] = [r[key] for r in rows]

path = pathlib.Path(__file__).resolve().parent.parent / "test" / "vectors" / "bs_vectors.json"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(out, indent=1))
print(f"wrote {len(rows)} vectors to {path}")
