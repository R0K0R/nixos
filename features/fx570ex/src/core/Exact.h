#pragma once
#include <QString>
#include <cstdint>

namespace fx {

// Exact real in the canonical Casio "S<=>D" form:
//
//     value = (p + q * sqrt(r)) / s        (piPow == 0)
//     value = (p + q * sqrt(r)) / s * pi   (piPow == 1)
//
// with r square-free and >= 1, s > 0, gcd(p, q, s) == 1.  When q == 0 the
// value is a plain rational; when p == 0 && q == 1 && s == 1 it is a bare
// surd.  Anything the calculator cannot hold in that shape (irrational logs,
// most trig results, overflow) degrades to `valid == false` and the engine
// falls back to the decimal approximation.
class Exact {
public:
    Exact() = default;
    static Exact rational(long long num, long long den = 1);
    static Exact surd(long long p, long long q, long long r, long long s);
    static Exact pi(long long num = 1, long long den = 1);
    static Exact invalid() { return Exact(); }

    bool isValid() const { return m_valid; }
    bool isRational() const { return m_valid && m_q == 0 && m_piPow == 0; }
    bool isInteger() const { return isRational() && m_s == 1; }
    bool isZero() const { return m_valid && m_p == 0 && m_q == 0; }
    bool hasPi() const { return m_piPow != 0; }

    long long p() const { return m_p; }
    long long q() const { return m_q; }
    long long r() const { return m_r; }
    long long s() const { return m_s; }

    double toDouble() const;

    Exact operator-() const;
    Exact operator+(const Exact &o) const;
    Exact operator-(const Exact &o) const { return *this + (-o); }
    Exact operator*(const Exact &o) const;
    Exact operator/(const Exact &o) const;

    Exact powInt(long long n) const;
    Exact sqrtExact() const;   // exact square root when one exists
    Exact reciprocal() const { return Exact::rational(1) / *this; }

    // Best-effort recovery of an exact value from a double (used after
    // operations that cannot track exactness symbolically).
    static Exact fromDouble(double v);

    // Textbook rendering: "3/4", "2sqrt(3)", "(1+sqrt(5))/2", "pi/6".
    // Uses the display glyphs the LCD understands.
    QString toDisplay() const;

    bool sameShapeAs(const Exact &o) const { return m_r == o.m_r && m_piPow == o.m_piPow; }

private:
    void normalize();

    bool m_valid = false;
    int m_piPow = 0;
    long long m_p = 0, m_q = 0, m_r = 1, m_s = 1;
};

long long gcdll(long long a, long long b);

} // namespace fx
