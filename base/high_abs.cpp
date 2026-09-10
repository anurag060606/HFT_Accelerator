#include <iostream>
#include <vector>
#include <map>
#include <string>
#include <cmath>
#include <iomanip>
#include <cstdint>
#include <fstream>
#include <random>

// --- MODULE 1: ITCH & OUCH PROTOCOLS ---
struct ItchMessage {
    char action;        // 'A' = Add, 'E' = Execute
    uint64_t order_id;
    std::string symbol;
    bool is_buy;        
    double price;
    uint32_t shares;
};

#pragma pack(push, 1)
struct OuchOrderPacket {
    char message_type;  // 'O' = Enter Order
    char buy_sell;      // 'B' = Buy, 'S' = Sell
    uint32_t shares;
    char symbol[8];
    double limit_price;
};
#pragma pack(pop)

// --- MODULE 2: LIMIT ORDER BOOK ---
class LimitOrderBook {
    std::map<double, uint32_t, std::greater<double>> bids;
    std::map<double, uint32_t, std::less<double>> asks;

public:
    void add_order(bool is_buy, double price, uint32_t shares) {
        if (is_buy) bids[price] += shares;
        else asks[price] += shares;
    }

    void execute_order(bool is_buy, double price, uint32_t shares) {
        if (is_buy) {
            auto it = bids.find(price);
            if (it != bids.end()) {
                it->second = (it->second > shares) ? (it->second - shares) : 0;
                if (it->second == 0) bids.erase(it);
            }
        } else {
            auto it = asks.find(price);
            if (it != asks.end()) {
                it->second = (it->second > shares) ? (it->second - shares) : 0;
                if (it->second == 0) asks.erase(it);
            }
        }
    }

    double get_best_bid() const { return bids.empty() ? 0.0 : bids.begin()->first; }
    double get_best_ask() const { return asks.empty() ? 0.0 : asks.begin()->first; }
    
    double get_mid_price() const {
        double bb = get_best_bid();
        double ba = get_best_ask();
        if (bb == 0.0 || ba == 0.0) return (bb != 0.0) ? bb : ba;
        return (bb + ba) / 2.0;
    }
};

// --- MODULE 3: HFT PORTFOLIO ENGINE ---
class HftPortfolioEngine {
    std::vector<std::string> symbols = {"AAPL", "MSFT", "NVDA"};
    const int num_assets = 3;
    std::map<std::string, LimitOrderBook> order_books;

    double current_mid_prices[3] = {180.0, 400.0, 900.0};
    double prev_mid_prices[3] = {180.0, 400.0, 900.0};

    uint64_t N = 0;
    double mean[3] = {0.0, 0.0, 0.0};
    double E_XXT[3][3] = {{0}};

    double current_shares[3] = {100, 50, 20};
    double cash_balance = 100000.0;

public:
    void process_itch(const ItchMessage& msg) {
        auto& lob = order_books[msg.symbol];
        if (msg.action == 'A') lob.add_order(msg.is_buy, msg.price, msg.shares);
        else if (msg.action == 'E') lob.execute_order(msg.is_buy, msg.price, msg.shares);

        int idx = get_symbol_index(msg.symbol);
        if (idx != -1) {
            prev_mid_prices[idx] = current_mid_prices[idx];
            double mid = lob.get_mid_price();
            if (mid > 0.0) current_mid_prices[idx] = mid;
        }
    }

    void step_pipeline() {
        double returns[3];
        for (int i = 0; i < num_assets; ++i) {
            double p_prev = (prev_mid_prices[i] == 0.0) ? 1.0 : prev_mid_prices[i];
            returns[i] = (current_mid_prices[i] - p_prev) / p_prev;
        }

        N++;
        double scale_old = (double)(N - 1) / N;
        double scale_new = 1.0 / N;

        for (int i = 0; i < num_assets; ++i) {
            mean[i] = mean[i] * scale_old + returns[i] * scale_new;
            for (int j = 0; j < num_assets; ++j) {
                E_XXT[i][j] = E_XXT[i][j] * scale_old + (returns[i] * returns[j]) * scale_new;
            }
        }
    }

    void evaluate_and_trade(std::ofstream& log_file, uint64_t tick_id) {
        double K[3][3];
        for (int i = 0; i < num_assets; ++i) {
            for (int j = 0; j < num_assets; ++j) {
                K[i][j] = E_XXT[i][j] - (mean[i] * mean[j]);
                if (i == j && std::abs(K[i][j]) < 1e-9) K[i][j] = 1e-4; // Regularization
            }
        }

        double raw_w[3] = {1.0 / K[0][0], 1.0 / K[1][1], 1.0 / K[2][2]};
        double sum = raw_w[0] + raw_w[1] + raw_w[2];
        double weights[3] = {raw_w[0]/sum, raw_w[1]/sum, raw_w[2]/sum};

        double total_val = cash_balance;
        for (int i = 0; i < num_assets; ++i) total_val += current_shares[i] * current_mid_prices[i];

        // Log performance metrics to CSV
        log_file << tick_id << "," << total_val << "," << cash_balance << "," 
                 << weights[0] << "," << weights[1] << "," << weights[2] << "\n";

        for (int i = 0; i < num_assets; ++i) {
            double target_qty = (total_val * weights[i]) / current_mid_prices[i];
            double delta = target_qty - current_shares[i];

            if (std::abs(delta) > 1.0) {
                OuchOrderPacket ouch;
                ouch.message_type = 'O';
                ouch.buy_sell = (delta > 0) ? 'B' : 'S';
                ouch.shares = static_cast<uint32_t>(std::abs(delta));
                symbols[i].copy(ouch.symbol, 8);
                ouch.limit_price = (delta > 0) ? order_books[symbols[i]].get_best_ask() 
                                               : order_books[symbols[i]].get_best_bid();
                if (ouch.limit_price == 0.0) ouch.limit_price = current_mid_prices[i];

                current_shares[i] += delta;
                cash_balance -= (delta * ouch.limit_price);
            }
        }
    }

private:
    int get_symbol_index(const std::string& sym) {
        for (int i = 0; i < num_assets; ++i) if (symbols[i] == sym) return i;
        return -1;
    }
};

// --- MODULE 1 (Cont.): STOCHASTIC ITCH GENERATOR ---
class ItchGenerator {
    std::mt19937 rng;
    std::normal_distribution<double> price_noise{0.0, 1.5};
    std::uniform_real_distribution<double> prob_dist{0.0, 1.0};
    uint64_t global_order_id = 1000;

public:
    ItchGenerator(unsigned int seed) : rng(seed) {}

    ItchMessage generate_tick(const std::string& symbol, double base_price, bool induce_shock = false) {
        double delta = price_noise(rng);
        if (induce_shock) delta -= 35.0; // Sharp drop event

        double new_price = base_price + delta;
        bool is_buy = prob_dist(rng) > 0.5;

        return ItchMessage{
            'A',
            global_order_id++,
            symbol,
            is_buy,
            new_price,
            static_cast<uint32_t>(100 + (rng() % 500))
        };
    }
};

// --- MODULE 4: SIMULATION ORCHESTRATOR ---
int main() {
    // Parameterizable configuration
    const uint64_t TOTAL_TICKS = 700;
    const unsigned int RANDOM_SEED = 42;

    std::ofstream csv_log("simulation_log.csv");
    csv_log << "Tick,TotalNetWorth,CashBalance,Weight_AAPL,Weight_MSFT,Weight_NVDA\n";

    HftPortfolioEngine engine;
    ItchGenerator generator(RANDOM_SEED);

    std::vector<std::string> symbols = {"AAPL", "MSFT", "NVDA"};
    double tracking_prices[3] = {180.0, 400.0, 900.0};

    // Seed initial order books
    for (int i = 0; i < 3; ++i) {
        engine.process_itch({'A', (uint64_t)i, symbols[i], true, tracking_prices[i] - 0.50, 1000});
        engine.process_itch({'A', (uint64_t)(i + 10), symbols[i], false, tracking_prices[i] + 0.50, 1000});
    }

    // Main simulation driver loop
    for (uint64_t t = 1; t <= TOTAL_TICKS; ++t) {
        // Induce a structural volatility shock on NVDA around tick 500
        bool shock = (t == 500);
        int target_idx = (t % 3); // Rotate asset updates

        ItchMessage msg = generator.generate_tick(symbols[target_idx], tracking_prices[target_idx], shock);
        tracking_prices[target_idx] = msg.price; // Update baseline reference

        engine.process_itch(msg);
        engine.step_pipeline();
        engine.evaluate_and_trade(csv_log, t);
    }

    csv_log.close();
    std::cout << "Simulation completed successfully. Metrics written to simulation_log.csv\n";
    return 0;
}