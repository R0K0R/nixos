#include "Exact.h"

#include <QtGlobal>
#include <cmath>
#include <cstdlib>

namespace fx {

namespace {
constexpr long long kLimit = 1000000000000LL; // 1e12: beyond this we give up on exactness

bool mulOverflows(long long a, long long b, long long *out)
{
    __int128 r = static_cast<__int128>(a) * static_cast<__int128>(b);
    if (r > kLimit || r < -kLimit)
        return true;
    *out = static_cast<long long>(r);
    return false;
}

bool addOverflows(long long a, long long b, long long *out)
{
    __int128 r = static_cast<__int128>(a) + static_cast<__int128>(b);
    if (r > kLimit || r < -kLimit)
        return true;
    *out = static_cast<long long>(r);
    return false;
}
} // namespace

long long gcdll(long long a, long long b)
{
    a = std::llabs(a);
    b = std::llabs(b);
    while (b) {
        long long t = a % b;
        a = b;
        b = t;
    }
    return a;
}

Exact Exact::rational(long long num, long long den)
{
    if (den == 0)
        return Exact();
    Exact e;
    e.m_valid = true;
    e.m_p = num;
    e.m_q = 0;
    e.m_r = 1;
    e.m_s = den;
    e.normalize();
    return e;
}

Exact Exact::surd(long long p, long long q, long long r, long long s)
{
    if (s == 0 || r < 0)
        return Exact();
    Exact e;
    e.m_valid = true;
    e.m_p = p;
    e.m_q = q;
    e.m_r = r;
    e.m_s = s;
    e.normalize();
    return e;
}

Exact Exact::pi(long long num, long long den)
{
    Exact e = rational(num, den);
    if (e.m_valid && !e.isZero())
        e.m_piPow = 1;
    return e;
}

void Exact::normalize()
{
    if (!m_valid)
        return;
    if (m_s == 0 || m_r < 0) {
        m_valid = false;
        return;
    }
    if (m_r == 0) { // sqrt(0) == 0
        m_r = 1;
        m_q = 0;
    }

    // Pull perfect-square factors out of the radicand.
    if (m_q != 0 && m_r > 1) {
        for (long long f = 2; f * f <= m_r; ++f) {
            long long sq = f * f;
            while (m_r % sq == 0) {
                m_r /= sq;
                if (mulOverflows(m_q, f, &m_q)) {
                    m_valid = false;
                    return;
                }
            }
        }
    }
    if (m_r == 1) { // sqrt(1) folds into the rational part
        if (addOverflows(m_p, m_q, &m_p)) {
            m_valid = false;
            return;
        }
        m_q = 0;
    }
    if (m_q == 0)
        m_r = 1;

    if (m_s < 0) {
        m_s = -m_s;
        m_p = -m_p;
        m_q = -m_q;
    }

    long long g = gcdll(gcdll(m_p, m_q), m_s);
    if (g > 1) {
        m_p /= g;
        m_q /= g;
        m_s /= g;
    }

    if (m_p == 0 && m_q == 0) {
        m_s = 1;
        m_r = 1;
        m_piPow = 0;
    }

    if (std::llabs(m_p) > kLimit || std::llabs(m_q) > kLimit || m_s > kLimit || m_r > kLimit)
        m_valid = false;
}

double Exact::toDouble() const
{
    if (!m_valid)
        return std::nan("");
    double v = (static_cast<double>(m_p) + static_cast<double>(m_q) * std::sqrt(static_cast<double>(m_r)))
            / static_cast<double>(m_s);
    if (m_piPow)
        v *= M_PI;
    return v;
}

Exact Exact::operator-() const
{
    Exact e = *this;
    e.m_p = -e.m_p;
    e.m_q = -e.m_q;
    return e;
}

Exact Exact::operator+(const Exact &o) const
{
    if (!m_valid || !o.m_valid)
        return Exact();
    if (isZero())
        return o;
    if (o.isZero())
        return *this;
    // Mixed pi/non-pi or differing radicands cannot stay in canonical form.
    if (m_piPow != o.m_piPow)
        return Exact();
    if (m_q != 0 && o.m_q != 0 && m_r != o.m_r)
        return Exact();

    long long r = (m_q != 0) ? m_r : o.m_r;
    long long p1, p2, q1, q2, s;
    if (mulOverflows(m_p, o.m_s, &p1) || mulOverflows(o.m_p, m_s, &p2)
        || mulOverflows(m_q, o.m_s, &q1) || mulOverflows(o.m_q, m_s, &q2)
        || mulOverflows(m_s, o.m_s, &s))
        return Exact();

    long long p, q;
    if (addOverflows(p1, p2, &p) || addOverflows(q1, q2, &q))
        return Exact();

    Exact e;
    e.m_valid = true;
    e.m_piPow = m_piPow;
    e.m_p = p;
    e.m_q = q;
    e.m_r = r;
    e.m_s = s;
    e.normalize();
    return e;
}

Exact Exact::operator*(const Exact &o) const
{
    if (!m_valid || !o.m_valid)
        return Exact();
    if (isZero() || o.isZero())
        return rational(0);
    if (m_piPow + o.m_piPow > 1)
        return Exact(); // pi^2 is outside the canonical shape

    // (p1 + q1 r1) (p2 + q2 r2) is only canonical when at most one side is a
    // surd, or when both share a radicand.
    long long p = 0, q = 0, r = 1, s = 0;
    if (m_q == 0) {
        if (mulOverflows(m_p, o.m_p, &p) || mulOverflows(m_p, o.m_q, &q))
            return Exact();
        r = o.m_r;
    } else if (o.m_q == 0) {
        if (mulOverflows(m_p, o.m_p, &p) || mulOverflows(m_q, o.m_p, &q))
            return Exact();
        r = m_r;
    } else if (m_r == o.m_r) {
        long long a, b, c, d;
        if (mulOverflows(m_p, o.m_p, &a) || mulOverflows(m_q, o.m_q, &b)
            || mulOverflows(b, m_r, &b) || addOverflows(a, b, &p))
            return Exact();
        if (mulOverflows(m_p, o.m_q, &c) || mulOverflows(m_q, o.m_p, &d) || addOverflows(c, d, &q))
            return Exact();
        r = m_r;
    } else {
        // Pure surds with different radicands still multiply cleanly.
        if (m_p == 0 && o.m_p == 0) {
            long long rr;
            if (mulOverflows(m_r, o.m_r, &rr) || mulOverflows(m_q, o.m_q, &q))
                return Exact();
            r = rr;
            p = 0;
        } else {
            return Exact();
        }
    }
    if (mulOverflows(m_s, o.m_s, &s))
        return Exact();

    Exact e;
    e.m_valid = true;
    e.m_piPow = m_piPow + o.m_piPow;
    e.m_p = p;
    e.m_q = q;
    e.m_r = r;
    e.m_s = s;
    e.normalize();
    return e;
}

Exact Exact::operator/(const Exact &o) const
{
    if (!m_valid || !o.m_valid || o.isZero())
        return Exact();
    if (o.m_piPow > m_piPow)
        return Exact(); // 1/pi is not canonical

    if (o.m_q == 0) {
        Exact inv;
        inv.m_valid = true;
        inv.m_p = o.m_s;
        inv.m_q = 0;
        inv.m_r = 1;
        inv.m_s = o.m_p;
        inv.normalize();
        if (!inv.m_valid)
            return Exact();
        Exact res = *this * inv;
        if (res.m_valid)
            res.m_piPow = m_piPow - o.m_piPow;
        return res;
    }

    // Rationalise: multiply numerator and denominator by the conjugate.
    Exact conj = o;
    conj.m_q = -conj.m_q;
    conj.m_piPow = 0;
    Exact denom = o * conj; // rational, pi cancels below
    if (!denom.m_valid || denom.m_q != 0 || denom.isZero())
        return Exact();
    Exact numer = *this * conj;
    if (!numer.m_valid)
        return Exact();
    Exact rat;
    rat.m_valid = true;
    rat.m_p = denom.m_p;
    rat.m_s = denom.m_s;
    rat.normalize();
    Exact res = numer / rat;
    if (res.m_valid)
        res.m_piPow = m_piPow - o.m_piPow;
    return res;
}

Exact Exact::powInt(long long n) const
{
    if (!m_valid)
        return Exact();
    if (n == 0)
        return rational(1);
    bool neg = n < 0;
    long long k = std::llabs(n);
    if (k > 64)
        return Exact();
    Exact acc = rational(1);
    Exact base = *this;
    while (k) {
        if (k & 1) {
            acc = acc * base;
            if (!acc.m_valid)
                return Exact();
        }
        k >>= 1;
        if (k) {
            base = base * base;
            if (!base.m_valid)
                return Exact();
        }
    }
    return neg ? rational(1) / acc : acc;
}

Exact Exact::sqrtExact() const
{
    if (!m_valid || m_piPow || m_q != 0 || m_p < 0)
        return Exact();
    // sqrt(p/s) == sqrt(p*s)/s
    long long ps;
    if (mulOverflows(m_p, m_s, &ps))
        return Exact();
    return surd(0, 1, ps, m_s);
}

Exact Exact::fromDouble(double v)
{
    if (!std::isfinite(v))
        return Exact();
    if (v == 0.0)
        return rational(0);

    auto asRational = [](double x, long long maxDen, long long *num, long long *den) -> bool {
        // Continued-fraction expansion, stopping at the first convergent that
        // reproduces x to full double precision.
        double sign = x < 0 ? -1.0 : 1.0;
        x = std::fabs(x);
        long long h0 = 0, h1 = 1, k0 = 1, k1 = 0;
        double frac = x;
        for (int i = 0; i < 40; ++i) {
            double fl = std::floor(frac);
            if (fl > 1e15)
                return false;
            long long a = static_cast<long long>(fl);
            long long h = a * h1 + h0;
            long long k = a * k1 + k0;
            if (k > maxDen || std::llabs(h) > kLimit)
                return false;
            h0 = h1; h1 = h;
            k0 = k1; k1 = k;
            double approx = static_cast<double>(h1) / static_cast<double>(k1);
            if (std::fabs(approx - x) <= 1e-13 * std::max(1.0, x)) {
                *num = static_cast<long long>(sign) * h1;
                *den = k1;
                return true;
            }
            double rem = frac - fl;
            if (rem < 1e-14)
                return false;
            frac = 1.0 / rem;
        }
        return false;
    };

    long long n = 0, d = 1;
    if (asRational(v, 1000000LL, &n, &d))
        return rational(n, d);
    if (asRational(v / M_PI, 1000LL, &n, &d))
        return pi(n, d);
    // sqrt form: v^2 rational and not a perfect square.
    double sq = v * v;
    if (asRational(sq, 1000LL, &n, &d) && n > 0) {
        Exact cand = surd(0, v < 0 ? -1 : 1, n * d, d);
        if (cand.isValid() && std::fabs(cand.toDouble() - v) <= 1e-12 * std::max(1.0, std::fabs(v)))
            return cand;
    }
    return Exact();
}

QString Exact::toDisplay() const
{
    if (!m_valid)
        return QString();

    const QString piGlyph = QStringLiteral("π");   // pi
    const QString rootOpen = QStringLiteral("√");  // sqrt

    auto numeratorText = [&]() -> QString {
        QString t;
        const bool hasP = m_p != 0;
        const bool hasQ = m_q != 0;
        if (hasP)
            t += QString::number(m_p);
        if (hasQ) {
            if (hasP)
                t += (m_q > 0 ? QStringLiteral("+") : QStringLiteral("-"));
            else if (m_q < 0)
                t += QStringLiteral("-");
            long long aq = std::llabs(m_q);
            if (aq != 1 || m_r == 1)
                t += QString::number(aq);
            if (m_r != 1)
                t += rootOpen + QString::number(m_r);
        }
        if (t.isEmpty())
            t = QStringLiteral("0");
        if (m_piPow) {
            const bool needsParens = hasP && hasQ;
            if (needsParens)
                t = QStringLiteral("(") + t + QStringLiteral(")");
            if (t == QStringLiteral("1"))
                t = piGlyph;
            else if (t == QStringLiteral("-1"))
                t = QStringLiteral("-") + piGlyph;
            else
                t += piGlyph;
        }
        return t;
    };

    QString num = numeratorText();
    if (m_s == 1)
        return num;
    return num + QStringLiteral("/") + QString::number(m_s);
}

} // namespace fx
