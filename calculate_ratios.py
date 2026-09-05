import yfinance as yf
import pandas as pd
import numpy as np


# ============================================================
# CONFIGURATION
# ============================================================

STOCK = "RELIANCE.NS"
BENCHMARK = "^NSEI"          # NIFTY 50
START_DATE = "2020-01-01"
END_DATE = "2026-01-01"

RISK_FREE_RATE = 0.07        # 7% annual risk-free rate
TRADING_DAYS = 252


# ============================================================
# DOWNLOAD DATA
# ============================================================

def download_data(ticker, start, end):
    df = yf.download(
        ticker,
        start=start,
        end=end,
        auto_adjust=True,
        progress=False
    )

    if df.empty:
        raise ValueError(f"No data found for {ticker}")

    # yfinance can return MultiIndex columns
    if isinstance(df.columns, pd.MultiIndex):
        df = df.xs(ticker, axis=1, level=1)

    return df


# ============================================================
# CAGR
# ============================================================

def calculate_cagr(prices):
    start_price = prices.iloc[0]
    end_price = prices.iloc[-1]

    start_date = prices.index[0]
    end_date = prices.index[-1]

    years = (end_date - start_date).days / 365.25

    if years <= 0:
        return np.nan

    cagr = (end_price / start_price) ** (1 / years) - 1

    return cagr


# ============================================================
# SHARPE RATIO
# ============================================================

def calculate_sharpe(returns, risk_free_rate=0.07):
    # Convert annual risk-free rate to daily rate
    daily_rf = (1 + risk_free_rate) ** (1 / TRADING_DAYS) - 1

    excess_returns = returns - daily_rf

    sharpe = (
        excess_returns.mean()
        / excess_returns.std()
        * np.sqrt(TRADING_DAYS)
    )

    return sharpe


# ============================================================
# SORTINO RATIO
# ============================================================

def calculate_sortino(returns, risk_free_rate=0.07):
    daily_rf = (1 + risk_free_rate) ** (1 / TRADING_DAYS) - 1

    excess_returns = returns - daily_rf

    # Only negative returns are treated as downside
    downside_returns = excess_returns[
        excess_returns < 0
    ]

    if len(downside_returns) == 0:
        return np.nan

    downside_deviation = np.sqrt(
        np.mean(downside_returns ** 2)
    )

    sortino = (
        excess_returns.mean()
        / downside_deviation
        * np.sqrt(TRADING_DAYS)
    )

    return sortino


# ============================================================
# BETA
# ============================================================

def calculate_beta(stock_returns, market_returns):
    covariance = stock_returns.cov(market_returns)

    market_variance = market_returns.var()

    if market_variance == 0:
        return np.nan

    beta = covariance / market_variance

    return beta


# ============================================================
# ALPHA
# ============================================================

def calculate_alpha(
    stock_returns,
    market_returns,
    beta,
    risk_free_rate=0.07
):
    # Annualized stock return
    stock_return = stock_returns.mean() * TRADING_DAYS

    # Annualized market return
    market_return = market_returns.mean() * TRADING_DAYS

    # CAPM expected return
    expected_return = (
        risk_free_rate
        + beta * (market_return - risk_free_rate)
    )

    alpha = stock_return - expected_return

    return alpha


# ============================================================
# MAIN ANALYSIS
# ============================================================

def analyze_stock(
    stock,
    benchmark,
    start_date,
    end_date,
    risk_free_rate
):

    print(f"\nDownloading {stock}...")
    stock_data = download_data(
        stock,
        start_date,
        end_date
    )

    print(f"Downloading {benchmark}...")
    market_data = download_data(
        benchmark,
        start_date,
        end_date
    )

    # --------------------------------------------------------
    # Prices
    # --------------------------------------------------------

    stock_prices = stock_data["Close"]
    market_prices = market_data["Close"]

    # --------------------------------------------------------
    # Daily returns
    # --------------------------------------------------------

    stock_returns = stock_prices.pct_change()
    market_returns = market_prices.pct_change()

    # --------------------------------------------------------
    # Align dates
    # --------------------------------------------------------

    data = pd.concat(
        [
            stock_returns.rename("stock"),
            market_returns.rename("market")
        ],
        axis=1
    ).dropna()

    stock_returns = data["stock"]
    market_returns = data["market"]

    # --------------------------------------------------------
    # Calculate metrics
    # --------------------------------------------------------

    cagr = calculate_cagr(stock_prices)

    sharpe = calculate_sharpe(
        stock_returns,
        risk_free_rate
    )

    sortino = calculate_sortino(
        stock_returns,
        risk_free_rate
    )

    beta = calculate_beta(
        stock_returns,
        market_returns
    )

    alpha = calculate_alpha(
        stock_returns,
        market_returns,
        beta,
        risk_free_rate
    )

    # --------------------------------------------------------
    # Results
    # --------------------------------------------------------

    results = {
        "Symbol": stock,
        "Start Date": stock_prices.index[0].strftime("%Y-%m-%d"),
        "End Date": stock_prices.index[-1].strftime("%Y-%m-%d"),
        "CAGR": cagr,
        "Sharpe": sharpe,
        "Sortino": sortino,
        "Beta": beta,
        "Alpha": alpha
    }

    return results


# ============================================================
# RUN
# ============================================================

if __name__ == "__main__":

    results = analyze_stock(
        stock=STOCK,
        benchmark=BENCHMARK,
        start_date=START_DATE,
        end_date=END_DATE,
        risk_free_rate=RISK_FREE_RATE
    )

    print("\n==============================")
    print("       STOCK ANALYSIS")
    print("==============================")

    print(f"Stock       : {results['Symbol']}")
    print(f"Start Date  : {results['Start Date']}")
    print(f"End Date    : {results['End Date']}")

    print(f"\nCAGR        : {results['CAGR']:.2%}")
    print(f"Sharpe      : {results['Sharpe']:.2f}")
    print(f"Sortino     : {results['Sortino']:.2f}")
    print(f"Beta        : {results['Beta']:.2f}")
    print(f"Alpha       : {results['Alpha']:.2%}")