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
PNG_W1 = "price_index_1_oct-dec_2025.png"
PNG_W2 = "price_index_2_sep_2026_to_now.png"
PNG_BOTH = "price_index_3_both_windows.png"

TODAY = pd.Timestamp("2026-09-22")
WINDOWS = {                       # capture-date basis (all the CSVs support)
    "Oct-Dec 2025": ("2025-10-15", "2025-12-15"),
    "Sep 2026-now": ("2026-09-01", str(TODAY.date())),
}

# Brands grouped by market segment. An index only means something within a
# segment: Contiki vs Globus is a segment comparison, not a price comparison.
# CHECK the site list the script prints and move anything that's misfiled.
TIERS = {
    "Premium coach": {
        "ttc":  ["trafalgar", "insight", "insight vacations", "luxury gold", "brendan",
                 "brendan vacations", "african travel", "red carnation"],
        "comp": ["globus", "collette", "tauck"],
    },
    "Value / youth": {
        "ttc":  ["contiki", "costsaver"],
        "comp": ["g adventures", "intrepid", "gate 1"],
    },
}
HEADLINE_TIER = "Premium coach"   # the tier the charts are built for
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
_ttc_all = [b.lower() for d in TIERS.values() for b in d["ttc"]]
comp["GROUP"] = np.where(site_l.isin(_ttc_all), "TTC", "Competitor")

print("\n  site split — CHECK THIS:")
print(comp.groupby(["GROUP", "SITE"]).size().sort_values(ascending=False).head(25).to_string())
if comp.GROUP.eq("TTC").sum() == 0:
    sys.exit("\nNo TTC sites matched. Add the right names to TTC_SITES and rerun.")

cw = tag_window(comp, "SCRAPE_DATE")
print(f"\n  rows in the two windows: {len(cw):,}")
print(cw.groupby(["WINDOW", "GROUP"]).size().to_string())

# ==================================================== 2. PRICE INDEX =======
TTC_MAP = {b.lower(): t for t, d in TIERS.items() for b in d["ttc"]}
COMP_MAP = {b.lower(): t for t, d in TIERS.items() for b in d["comp"]}

sl = cw.SITE.astype(str).str.strip().str.lower()
cw["TIER"] = sl.map(lambda x: TTC_MAP.get(x) or COMP_MAP.get(x))
unmapped = cw.loc[cw.TIER.isna(), "SITE"].value_counts()
if len(unmapped):
    print("\n  sites in no tier — excluded, move them into TIERS if they matter:")
    print(unmapped.to_string())
cw = cw[cw.TIER.notna()]

per_site = (cw.groupby([COUNTRY_COL, "TIER", "WINDOW", "GROUP", "SITE"])
            .agg(ppn=("PPN", "median"), n=("PPN", "size")).reset_index())
per_site = per_site[per_site.n >= MIN_SITE_ROWS]

# Constant panel: a brand must appear in BOTH windows for that country, else a
# change in which brands were scraped shows up as a change in price position.
nwin = per_site.groupby([COUNTRY_COL, "TIER", "GROUP", "SITE"]).WINDOW.transform("nunique")
print(f"\n  constant panel: dropped {(nwin < len(WINDOWS)).sum()} brand-country rows "
      f"present in only one window")
per_site = per_site[nwin == len(WINDOWS)]

# Median per brand, then median across brands, so volume can't define the market
med = (per_site.groupby([COUNTRY_COL, "TIER", "WINDOW", "GROUP"])
       .agg(ppn=("ppn", "median"), n=("n", "sum"), sites=("SITE", "nunique")).reset_index())
wide = med.pivot_table(index=[COUNTRY_COL, "TIER", "WINDOW"], columns="GROUP",
                       values=["ppn", "n", "sites"]).reset_index()
wide.columns = [a if not b else f"{a}_{b}" for a, b in wide.columns]
wide = wide.rename(columns={COUNTRY_COL: "country"})
wide = wide.dropna(subset=["ppn_TTC", "ppn_Competitor"])
wide["price_index"] = 100 * wide.ppn_TTC / wide.ppn_Competitor
wide["thin"] = (wide.n_TTC < MIN_ROWS) | (wide.n_Competitor < MIN_ROWS)
print("\n  countries with both sides present, by tier:")
print(wide.groupby(["TIER", "WINDOW"]).country.nunique().to_string())

h = wide[wide.TIER == HEADLINE_TIER]
idx = h.pivot(index="country", columns="WINDOW", values="price_index")
idx = idx.reindex(columns=list(WINDOWS)).dropna()
ccols = [c for c in ["n_TTC", "n_Competitor", "sites_TTC", "sites_Competitor"] if c in h.columns]
idx["change_pts"] = idx[list(WINDOWS)[1]] - idx[list(WINDOWS)[0]]
idx = idx.join(h.groupby("country")[ccols].min()).join(h.groupby("country").thin.any())

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

print(f"\n=== PRICE INDEX, {HEADLINE_TIER} (100 = parity), top {TOP_N} by {basis} ===")
show = [c for c in [*WINDOWS, "change_pts", "sites_Competitor", "n_TTC", "n_Competitor", "thin", "revenue"] if c in top.columns]
print(top[show].round(1).to_string())

# ============================================================ 4. CHARTS ====
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

S1, S2 = "#2a78d6", "#eb6834"          # validated categorical slots 1 and 2
INK, INK2, SURFACE = "#0b0b0b", "#52514e", "#fcfcfb"
GRID, AXIS = "#e5e4e0", "#d9d8d4"
w1, w2 = list(WINDOWS)


def bar_chart(df, cols, colors, title, path):
    """Horizontal bars, one or two series, parity line at 100."""
    p = df.dropna(subset=cols)
    if p.empty:
        print(f"  (nothing to plot for {path})")
        return
    y = np.arange(len(p))
    two = len(cols) == 2
    h = 0.38 if two else 0.55
    fig, ax = plt.subplots(figsize=(9, max(4, 0.52 * len(p) + 1.7)), facecolor=SURFACE)
    ax.set_facecolor(SURFACE)

    offs = [h / 2 + 0.01, -h / 2 - 0.01] if two else [0]
    for col, colr, off in zip(cols, colors, offs):
        ax.barh(y + off, p[col], height=h, color=colr, label=col, zorder=3)
        for yi, v in enumerate(p[col]):
            ax.text(v + 1, yi + off, f"{v:.0f}", va="center", fontsize=8, color=INK2)

    ax.axvline(100, color=INK2, lw=1, ls="--", zorder=2)
    ax.text(100, len(p) - 0.3, " parity", color=INK2, fontsize=8, va="bottom")
    ax.set_yticks(y, [f"{c} *" if t else c for c, t in zip(p.index, p.thin)],
                  fontsize=9, color=INK)
    ax.set_xlabel("Price index  (TTC median USD per night ÷ competitor median USD per night × 100)",
                  fontsize=9, color=INK2)
    ax.set_title(title, fontsize=12, color=INK, pad=28 if two else 12, loc="left")
    if two:      # one series needs no legend — the title names it
        ax.legend(frameon=False, fontsize=9, labelcolor=INK2, ncol=2,
                  loc="lower left", bbox_to_anchor=(0, 1.005))
    ax.grid(axis="x", color=GRID, lw=0.8, zorder=0)
    ax.set_axisbelow(True)
    for side in ["top", "right", "left"]:
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(AXIS)
    ax.tick_params(length=0, colors=INK2, labelsize=9)
    ax.set_xlim(0, max(110, p[cols].max().max() * 1.12))
    fig.text(0.01, 0.005, f"* fewer than {MIN_ROWS} scraped prices on one side — treat as indicative",
             fontsize=8, color=INK2)
    fig.tight_layout()
    fig.savefig(path, dpi=200, facecolor=SURFACE)
    plt.close(fig)
    print(f"  wrote {path}")


# Deliverable 1 and 2: each window on its own, ranked by that window's position
a1 = top.sort_values(w1)
a2 = top.sort_values(w2)
print("\n=== charts ===")
bar_chart(a1, [w1], [S1], f"TTC vs competitors, {HEADLINE_TIER} — {w1}", PNG_W1)
bar_chart(a2, [w2], [S2], f"TTC vs competitors, {HEADLINE_TIER} — {w2}", PNG_W2)
# Secondary: the two side by side, ordered by movement
bar_chart(top.sort_values("change_pts"), [w1, w2], [S1, S2],
          f"TTC vs competitors, {HEADLINE_TIER} — both windows", PNG_BOTH)

# =========================================================== 5. EXPORT =====
base = ["ppn_TTC", "ppn_Competitor", "price_index", "n_TTC", "n_Competitor", "sites_Competitor"]


def window_sheet(win):
    d = h[h.WINDOW == win].set_index("country")
    cols = [c for c in base if c in d.columns]
    d = d[cols].join(idx[["thin"]]).sort_values("price_index", ascending=False)
    return d.loc[[c for c in top.index if c in d.index]].round(2)


with pd.ExcelWriter(OUT_XLSX, engine="openpyxl") as xw:
    window_sheet(w1).to_excel(xw, sheet_name="1_Oct-Dec_2025")
    window_sheet(w2).to_excel(xw, sheet_name="2_Sep_2026_to_now")
    top[show].round(2).to_excel(xw, sheet_name="3_comparison")
    idx[show].round(2).to_excel(xw, sheet_name="all_countries")
    per_site.round(2).to_excel(xw, sheet_name="by_site", index=False)
    wide.round(2).to_excel(xw, sheet_name="all_tiers", index=False)
print(f"  wrote {OUT_XLSX}")

print(f"\n=== {w1} (deliverable 1) ===")
print(window_sheet(w1).to_string())
print(f"\n=== {w2} (deliverable 2) ===")
print(window_sheet(w2).to_string())

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
