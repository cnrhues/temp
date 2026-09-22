"""
TTC vs competitor price index, US market — built from the two CSV exports.

Compares median price per night by destination country, TTC brands against
competitor brands, using the competitor scrape as the source for BOTH sides
(it contains TTC's own sites), so advertised price is compared with advertised
price. The sales CSV is used only to rank countries by TTC revenue and pax.

Edit the CONFIG block, then:  python ttc_price_index.py
Outputs: price_index.xlsx, price_index.png, and a printed caveats block.
"""
import re
import sys
import numpy as np
import pandas as pd

# ============================================================== CONFIG ======
COMP_CSV = "competitor.csv"      # export from REPORTING.COMPETITOR_RAW
SALES_CSV = "sales.csv"          # export from SALES.SALES_MOVEMENT
OUT_XLSX = "price_index.xlsx"
OUT_PNG = "price_index.png"

TODAY = pd.Timestamp("2026-09-22")
WINDOWS = {                       # capture-date basis (all the CSVs support)
    "Oct-Dec 2025": ("2025-10-15", "2025-12-15"),
    "Sep 2026-now": ("2026-09-01", str(TODAY.date())),
}

# Sites that are TTC brands. CHECK THIS against comp.SITE.value_counts() —
# anything misfiled here goes straight into the headline.
TTC_SITES = ["trafalgar", "contiki", "insight", "insight vacations", "costsaver",
             "luxury gold", "brendan", "brendan vacations", "african travel",
             "uniworld", "red carnation", "at&ro", "ttc"]
EXCLUDE_SITES = ["viking", "avalon"]   # river cruise — not comparable to coach tours

TWIN_RE = re.compile(r"twin|double|dbl|share", re.I)   # twin-share room types
MIN_ROWS = 30                     # per group, per window; below this = thin
MIN_SITE_ROWS = 10                # a site needs this many prices to count in a country
TOP_N = 12                        # countries on the chart
COUNTRY_COL = "TOUR_COUNTRY_FIRST"   # fallback to TOUR_COUNTRY if absent

pd.set_option("display.width", 200)
pd.set_option("display.max_rows", 100)


def load(path, date_cols):
    try:
        df = pd.read_csv(path, low_memory=False)
    except FileNotFoundError:
        sys.exit(f"Can't find {path} — set the path in CONFIG at the top.")
    df.columns = [c.strip().upper() for c in df.columns]
    for c in date_cols:
        if c in df.columns:
            df[c] = pd.to_datetime(df[c], errors="coerce", format="mixed")
    return df


def tag_window(df, col):
    out = []
    for name, (s, e) in WINDOWS.items():
        m = df[col].between(pd.Timestamp(s), pd.Timestamp(e))
        out.append(df[m].assign(WINDOW=name))
    return pd.concat(out, ignore_index=True) if out else df.iloc[:0]


# =============================================== 1. COMPETITOR SCRAPE =======
comp = load(COMP_CSV, ["SCRAPE_DATE", "DEPARTURE_DATE"])
print(f"=== scrape loaded: {len(comp):,} rows ===")

if COUNTRY_COL not in comp.columns:
    COUNTRY_COL = "TOUR_COUNTRY"
need = {"SITE", "PRICE", "SCRAPE_DATE", COUNTRY_COL}
missing = need - set(comp.columns)
if missing:
    sys.exit(f"Scrape CSV is missing {missing} — check the export.")

# price per night: use PRICE_PN if present (verified = PRICE / TOUR_NIGHTS_NO_AIR)
if "PRICE_PN" in comp.columns:
    comp["PPN"] = pd.to_numeric(comp.PRICE_PN, errors="coerce")
else:
    comp["PPN"] = (pd.to_numeric(comp.PRICE, errors="coerce")
                   / pd.to_numeric(comp.TOUR_NIGHTS_NO_AIR, errors="coerce").replace(0, np.nan))

n0 = len(comp)
if "CURRENCY" in comp.columns:
    comp = comp[comp.CURRENCY.astype(str).str.upper() == "USD"]
comp = comp[comp.PPN.between(20, 3000)]                      # drop junk/luxury outliers
print(f"  after USD + sane-price filter: {len(comp):,} ({n0 - len(comp):,} dropped)")

# twin-share only, where room type is populated
if "ROOM_TYPE" in comp.columns:
    rt = comp.ROOM_TYPE.fillna("")
    twin = rt.str.contains(TWIN_RE)
    print(f"  room type: {twin.sum():,} twin/double, {(rt == '').sum():,} blank, "
          f"{(~twin & (rt != '')).sum():,} other — keeping twin/double + blank")
    comp = comp[twin | (rt == "")]

# dedupe: NULL-safe, unlike a SQL || concat
dedup_key = [c for c in ["SITE", "TOUR_CODE", "DEPARTURE_DATE", "SCRAPE_DATE", "ROOM_TYPE"]
             if c in comp.columns]
before = len(comp)
comp = comp.drop_duplicates(dedup_key)
print(f"  deduped on {dedup_key}: {before - len(comp):,} rows removed")

site_l = comp.SITE.astype(str).str.strip().str.lower()
comp = comp[~site_l.isin([s.lower() for s in EXCLUDE_SITES])]
site_l = comp.SITE.astype(str).str.strip().str.lower()
comp["GROUP"] = np.where(site_l.isin([s.lower() for s in TTC_SITES]), "TTC", "Competitor")

print("\n  site split — CHECK THIS:")
print(comp.groupby(["GROUP", "SITE"]).size().sort_values(ascending=False).head(25).to_string())
if comp.GROUP.eq("TTC").sum() == 0:
    sys.exit("\nNo TTC sites matched. Add the right names to TTC_SITES and rerun.")

cw = tag_window(comp, "SCRAPE_DATE")
print(f"\n  rows in the two windows: {len(cw):,}")
print(cw.groupby(["WINDOW", "GROUP"]).size().to_string())

# ==================================================== 2. PRICE INDEX =======
# Median per SITE first, then median across sites, so one high-volume operator
# can't define "the market". G Adventures + Intrepid are ~90% of scraped rows.
per_site = (cw.groupby([COUNTRY_COL, "WINDOW", "GROUP", "SITE"])
            .agg(ppn=("PPN", "median"), n=("PPN", "size")).reset_index())
per_site = per_site[per_site.n >= MIN_SITE_ROWS]
med = (per_site.groupby([COUNTRY_COL, "WINDOW", "GROUP"])
       .agg(ppn=("ppn", "median"), n=("n", "sum"), sites=("SITE", "nunique")).reset_index())
wide = med.pivot_table(index=[COUNTRY_COL, "WINDOW"], columns="GROUP",
                       values=["ppn", "n", "sites"]).reset_index()
wide.columns = [a if not b else f"{a}_{b}" for a, b in wide.columns]
wide = wide.rename(columns={COUNTRY_COL: "country"})
wide = wide.dropna(subset=["ppn_TTC", "ppn_Competitor"])
wide["price_index"] = 100 * wide.ppn_TTC / wide.ppn_Competitor
wide["thin"] = (wide.n_TTC < MIN_ROWS) | (wide.n_Competitor < MIN_ROWS)

idx = wide.pivot(index="country", columns="WINDOW", values="price_index")
idx = idx.reindex(columns=list(WINDOWS)).dropna()
ccols = [c for c in ["n_TTC", "n_Competitor", "sites_TTC", "sites_Competitor"] if c in wide.columns]
counts = wide.groupby("country")[ccols].min()
idx["change_pts"] = idx[list(WINDOWS)[1]] - idx[list(WINDOWS)[0]]
idx = idx.join(counts).join(wide.groupby("country").thin.any())

# ====================================== 3. RANK BY TTC SALES (optional) ====
rank = None
try:
    sales = load(SALES_CSV, ["RELEVANT_DATE_LOCAL", "START_AT"])
    if "PAX" in sales.columns and "GROSS_PRICE_USD" in sales.columns:
        s = sales.copy()
        if "REGION_REPORT" in s.columns:
            s = s[s.REGION_REPORT.astype(str).str.upper().isin(["USA", "US"])]
        s["PAX"] = pd.to_numeric(s.PAX, errors="coerce")
        s["GROSS_PRICE_USD"] = pd.to_numeric(s.GROSS_PRICE_USD, errors="coerce")
        cancels = (s.PAX <= 0).sum()
        print(f"\n=== sales: {len(s):,} US rows, {cancels:,} with PAX <= 0 (cancellations?) ===")
        ratio = (s[s.PAX > 0].groupby("PAX").GROSS_PRICE_USD.median())
        print("  median GROSS_PRICE_USD by PAX — if it roughly doubles from 1 to 2,\n"
              "  the column is per booking and revenue below is still fine:")
        print(ratio.head(5).round(0).to_string())
        s = s[s.PAX > 0]
        ccol = "START_COUNTRY" if "START_COUNTRY" in s.columns else None
        if ccol:
            rank = (s.groupby(ccol)
                    .agg(revenue=("GROSS_PRICE_USD", "sum"), pax=("PAX", "sum"))
                    .sort_values("revenue", ascending=False))
            rank.index = rank.index.astype(str).str.strip()
            print(f"\n  ranked {len(rank)} countries by TTC US revenue")
except SystemExit:
    print("\n  (sales CSV not loaded — ranking by scrape coverage instead)")
except Exception as e:
    print(f"\n  (sales CSV unusable: {e} — ranking by scrape coverage instead)")

if rank is not None:
    idx = idx.join(rank, how="left")
    idx["rank_by"] = idx.revenue.fillna(0)
    basis = "TTC US revenue"
else:
    idx["rank_by"] = idx[["n_TTC", "n_Competitor"]].min(axis=1)
    basis = "scrape coverage (no sales data)"

idx = idx.sort_values("rank_by", ascending=False)
top = idx.head(TOP_N).sort_values("change_pts")

print(f"\n=== PRICE INDEX by country (100 = parity), top {TOP_N} by {basis} ===")
show = [c for c in [*WINDOWS, "change_pts", "sites_Competitor", "n_TTC", "n_Competitor", "thin", "revenue"] if c in top.columns]
print(top[show].round(1).to_string())

# ============================================================ 4. CHART =====
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

S1, S2 = "#2a78d6", "#eb6834"          # validated categorical slots 1 and 2
INK, INK2, SURFACE = "#0b0b0b", "#52514e", "#fcfcfb"

p = top.dropna(subset=list(WINDOWS))
y = np.arange(len(p))
h = 0.38
fig, ax = plt.subplots(figsize=(9, max(4, 0.52 * len(p) + 1.6)), facecolor=SURFACE)
ax.set_facecolor(SURFACE)
w1, w2 = list(WINDOWS)
ax.barh(y + h / 2 + 0.01, p[w1], height=h, color=S1, label=w1, zorder=3)
ax.barh(y - h / 2 - 0.01, p[w2], height=h, color=S2, label=w2, zorder=3)
ax.axvline(100, color=INK2, lw=1, ls="--", zorder=2)
ax.text(100, len(p) - 0.35, " parity", color=INK2, fontsize=8, va="bottom")

for yi, (a, b) in enumerate(zip(p[w1], p[w2])):
    ax.text(a + 1, yi + h / 2 + 0.01, f"{a:.0f}", va="center", fontsize=8, color=INK2)
    ax.text(b + 1, yi - h / 2 - 0.01, f"{b:.0f}", va="center", fontsize=8, color=INK2)

labels = [f"{c} *" if t else c for c, t in zip(p.index, p.thin)]
ax.set_yticks(y, labels, fontsize=9, color=INK)
ax.set_xlabel("Price index  (TTC median USD per night ÷ competitor median USD per night × 100)",
              fontsize=9, color=INK2)
ax.set_title("TTC price position vs competitors, US market", fontsize=12, color=INK, pad=28, loc="left")
ax.legend(frameon=False, fontsize=9, labelcolor=INK2, ncol=2,
          loc="lower left", bbox_to_anchor=(0, 1.005))
ax.grid(axis="x", color="#e5e4e0", lw=0.8, zorder=0)
ax.set_axisbelow(True)
for side in ["top", "right", "left"]:
    ax.spines[side].set_visible(False)
ax.spines["bottom"].set_color("#d9d8d4")
ax.tick_params(length=0, colors=INK2, labelsize=9)
ax.set_xlim(0, max(110, p[[w1, w2]].max().max() * 1.12))
fig.text(0.01, 0.005, "* fewer than %d scraped prices on one side — treat as indicative" % MIN_ROWS,
         fontsize=8, color=INK2)
fig.tight_layout()
fig.savefig(OUT_PNG, dpi=200, facecolor=SURFACE)
print(f"\nwrote {OUT_PNG}")

with pd.ExcelWriter(OUT_XLSX, engine="openpyxl") as xw:
    top[show].round(2).to_excel(xw, sheet_name="summary")
    per_site.round(2).to_excel(xw, sheet_name="by_site", index=False)
    idx[show].round(2).to_excel(xw, sheet_name="all_countries")
    wide.round(2).to_excel(xw, sheet_name="detail", index=False)
print(f"wrote {OUT_XLSX}")

print("""
================================ CAVEATS =================================
Read these out. They are the analysis, not an apology for it.

1. Compares ADVERTISED prices on both sides — TTC brands and competitor
   brands from the same scrape — so it is like-for-like. It does not
   reflect what TTC actually achieved after discounting.
2. Matched at DESTINATION COUNTRY level, not tour level. Differences in
   itinerary, duration, hotel standard and inclusions are not controlled
   for. Normalised to price per night to remove length effects.
3. CAPTURE-DATE basis only. The departure-date view could not be built:
   both extracts were filtered on capture dates, so departures in the
   windows were never exported.
4. Windows are not seasonally comparable — Oct-Dec vs September. Some of
   the movement is seasonality, not competitive position.
5. Rows marked * rest on thin data. Do not price off them.
6. The dev SALES_MOVEMENT view was replaced at 05:41 today and now returns
   zero rows. Figures here come from a CSV exported before that. The view
   needs fixing before this can be rerun or extended.
=========================================================================
""")
