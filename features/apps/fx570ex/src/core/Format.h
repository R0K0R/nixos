#pragma once
#include "Value.h"

#include <QString>

namespace fx {

enum class DisplayFormat { Norm1, Norm2, Fix, Sci, Eng };

struct FormatOptions {
    DisplayFormat format = DisplayFormat::Norm1;
    int digits = 3;            // Fix decimals or Sci significant digits
    bool engineering = false;  // ENG symbol / exponent forced to a multiple of 3
    bool thousandsSeparator = false;
};

// Renders a number the way the LCD would: 10 significant digits, an exponent
// shown as "x10^n", and Norm1/Norm2 switching thresholds taken from the manual.
QString formatNumber(double value, const FormatOptions &opt);

// Full value rendering, including complex (a+bi) and matrices.
QString formatValue(const Value &v, const FormatOptions &opt);

} // namespace fx
