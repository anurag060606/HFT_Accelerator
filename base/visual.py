import pandas as pd
import matplotlib.pyplot as plt

df = pd.read_csv("base/simulation_log.csv")

fig, axes = plt.subplots(3, 1, figsize=(10, 12), sharex=True)

# Subplot 1: Total Portfolio Net Worth
axes[0].plot(df["Tick"], df["TotalNetWorth"], label="Total Net Worth", color="green")
axes[0].set_title("Portfolio Net Worth")
axes[0].set_ylabel("USD ($)")
axes[0].legend()
axes[0].grid(True)

# Subplot 2: Cash Balance (Now using the 3rd subplot slot properly)
axes[1].plot(df["Tick"], df["CashBalance"], label="Cash Balance", color="blue")
axes[1].set_title("Available Cash Balance")
axes[1].set_ylabel("USD ($)")
axes[1].legend()
axes[1].grid(True)

# Subplot 3: Dynamic Markowitz Target Weights
axes[2].plot(df["Tick"], df["Weight_AAPL"], label="AAPL", color="tab:blue")
axes[2].plot(df["Tick"], df["Weight_MSFT"], label="MSFT", color="tab:orange")
axes[2].plot(df["Tick"], df["Weight_NVDA"], label="NVDA (Shock Target)", color="tab:red")
axes[2].set_title("Dynamic Markowitz Target Weights")
axes[2].set_xlabel("Simulation Tick")
axes[2].set_ylabel("Weight Ratio")
axes[2].legend()
axes[2].grid(True)

plt.tight_layout()
plt.savefig("simulation_results.png", dpi=300)
print("Plot saved successfully as simulation_results.png")