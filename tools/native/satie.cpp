// Process boundary: the D runtime never links the C++ solver or its runtime.
#include "DependencySAT/DependencySAT.hpp"
#include <iostream>

int main()
{
    try {
        satie::PluginHost host;
        satie::stdplugin::DependencySAT plugin;
        plugin.install(host);
        std::string line;
        if (!std::getline(std::cin, line))
            throw std::invalid_argument("missing preference list");
        std::vector<int> preferences;
        std::istringstream input(line);
        int variable;
        while (input >> variable) {
            if (variable <= 0)
                throw std::invalid_argument("invalid preference variable");
            preferences.push_back(variable);
        }
        if (!input.eof())
            throw std::invalid_argument("invalid preference list");
        satie::PluginArguments clauses;
        while (std::getline(std::cin, line))
            clauses.push_back(line);
        const auto satisfiable = [&] {
            return clauses.empty() || host.invoke("dependency.sat", clauses) == "SAT";
        };
        if (!satisfiable()) {
            std::cout << "UNSAT\n";
            return 0;
        }
        std::vector<int> selected;
        for (int preferred : preferences) {
            clauses.push_back(std::to_string(preferred));
            if (satisfiable())
                selected.push_back(preferred);
            else
                clauses.back() = std::to_string(-preferred);
        }
        std::cout << "SAT\n";
        for (int chosen : selected)
            std::cout << chosen << '\n';
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
