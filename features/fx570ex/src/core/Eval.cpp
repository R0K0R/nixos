#include "Eval.h"

#include <QRandomGenerator>
#include <cmath>

namespace fx {

namespace {

constexpr double kEpsilon = 1e-13;

void requireFinite(double v)
{
    if (!std::isfinite(v))
        throw CalcError{ ErrorKind::Math, QStringLiteral("result is not finite") };
}

// Casio snaps trig results that land within display precision of a clean value,
// so sin(180 deg) shows 0 rather than 1.2e-16.
double snap(double v)
{
    const double r = std::round(v);
    if (std::fabs(v - r) < 1e-12 * std::max(1.0, std::fabs(v)))
        return r;
    if (std::fabs(v) < 1e-13)
        return 0.0;
    return v;
}

bool isIntegral(double v, long long *out = nullptr)
{
    const double r = std::round(v);
    if (std::fabs(v - r) > 1e-9 * std::max(1.0, std::fabs(v)))
        return false;
    if (std::fabs(r) > 9.2e18)
        return false;
    if (out)
        *out = static_cast<long long>(r);
    return true;
}

// Exact values for the angles a ClassWiz shows symbolically.
bool exactTrig(const QString &fn, double degrees, Exact *out)
{
    double norm = std::fmod(degrees, 360.0);
    if (norm < 0)
        norm += 360.0;
    if (std::fabs(norm - std::round(norm)) > 1e-9)
        return false;
    const int a = static_cast<int>(std::lround(norm)) % 360;
    if (a % 15 != 0)
        return false;

    auto sinTable = [](int deg) -> Exact {
        switch (deg) {
        case 0:   return Exact::rational(0);
        case 30:  return Exact::rational(1, 2);
        case 45:  return Exact::surd(0, 1, 2, 2);
        case 60:  return Exact::surd(0, 1, 3, 2);
        case 90:  return Exact::rational(1);
        case 15:  return Exact::invalid();  // (sqrt6-sqrt2)/4 needs two radicands
        case 75:  return Exact::invalid();
        default:  return Exact::invalid();
        }
    };

    Exact r;
    if (fn == QLatin1String("sin")) {
        const int q = a % 180;
        Exact base = sinTable(q <= 90 ? q : 180 - q);
        if (!base.isValid())
            return false;
        r = (a < 180) ? base : -base;
    } else if (fn == QLatin1String("cos")) {
        const int shifted = (a + 90) % 360;
        const int q = shifted % 180;
        Exact base = sinTable(q <= 90 ? q : 180 - q);
        if (!base.isValid())
            return false;
        r = (shifted < 180) ? base : -base;
    } else if (fn == QLatin1String("tan")) {
        if (a % 180 == 90)
            return false; // undefined; the caller raises Math ERROR
        Exact s, c;
        if (!exactTrig(QStringLiteral("sin"), a, &s) || !exactTrig(QStringLiteral("cos"), a, &c))
            return false;
        if (c.isZero())
            return false;
        r = s / c;
    } else {
        return false;
    }
    if (!r.isValid())
        return false;
    *out = r;
    return true;
}

} // namespace

double factorial(double n)
{
    long long k = 0;
    if (!isIntegral(n, &k) || k < 0)
        throw CalcError{ ErrorKind::Math, QStringLiteral("factorial needs a non-negative integer") };
    if (k > 169)
        throw CalcError{ ErrorKind::Math, QStringLiteral("factorial overflow") };
    double acc = 1.0;
    for (long long i = 2; i <= k; ++i)
        acc *= static_cast<double>(i);
    return acc;
}

double Evaluator::toAngle(double radians) const
{
    switch (m_ctx.angle) {
    case AngleUnit::Deg: return radians * 180.0 / M_PI;
    case AngleUnit::Rad: return radians;
    case AngleUnit::Gra: return radians * 200.0 / M_PI;
    }
    return radians;
}

double Evaluator::fromAngle(double v) const
{
    switch (m_ctx.angle) {
    case AngleUnit::Deg: return v * M_PI / 180.0;
    case AngleUnit::Rad: return v;
    case AngleUnit::Gra: return v * M_PI / 200.0;
    }
    return v;
}

Value Evaluator::lookupVar(const QString &name) const
{
    auto it = m_ctx.vars.constFind(name);
    if (it == m_ctx.vars.constEnd())
        return Value(Real(0.0, Exact::rational(0)));
    return it.value();
}

Value Evaluator::eval(const AstP &node)
{
    if (!node)
        throw CalcError{ ErrorKind::Syntax, QStringLiteral("missing operand") };
    if (++m_ctx.depth > 64) {
        --m_ctx.depth;
        throw CalcError{ ErrorKind::Stack, QStringLiteral("expression nested too deeply") };
    }
    struct DepthGuard {
        Context &c;
        ~DepthGuard() { --c.depth; }
    } guard{ m_ctx };

    const Ast &n = *node;
    switch (n.op) {
    case AstOp::Number:
        return Value(Real(n.num, n.exact));

    case AstOp::Constant: {
        if (n.name == QLatin1String("pi"))
            return Value(Real(M_PI, Exact::pi()));
        if (n.name == QLatin1String("e"))
            return Value(Real(M_E));
        if (n.name == QLatin1String("i"))
            return Value::complex(Cplx(0.0, 1.0));
        if (n.name == QLatin1String("Ran#"))
            return Value(Real(std::floor(QRandomGenerator::global()->generateDouble() * 1000.0) / 1000.0));
        throw CalcError{ ErrorKind::Syntax, QStringLiteral("unknown constant") };
    }

    case AstOp::Variable:
        return lookupVar(n.name);

    case AstOp::Store: {
        Value v = eval(n.args[0]);
        m_ctx.vars[n.name] = v;
        return v;
    }

    case AstOp::Neg: {
        Value v = eval(n.args[0]);
        if (v.isComplex())
            return Value::complex(-v.c());
        if (v.isMatrix() || v.isVector()) {
            Matrix m = v.mat();
            for (int r = 0; r < m.rows(); ++r)
                for (int c = 0; c < m.cols(); ++c)
                    m.at(r, c) = -m.at(r, c);
            return v.isVector() ? Value::vector(m) : Value::matrix(m);
        }
        const Real &r = v.real();
        return Value(Real(-r.d, r.hasExact() ? -r.e : Exact::invalid()));
    }

    case AstOp::Factorial:
        return Value(Real(factorial(eval(n.args[0]).d())));

    case AstOp::Percent: {
        Value v = eval(n.args[0]);
        const Real &r = v.real();
        return Value(Real(r.d / 100.0, r.hasExact() ? r.e / Exact::rational(100) : Exact::invalid()));
    }

    case AstOp::DegMinSec: {
        const double v = eval(n.args[0]).d();
        double radians;
        if (n.name == QLatin1String("deg"))
            radians = v * M_PI / 180.0;
        else if (n.name == QLatin1String("grad"))
            radians = v * M_PI / 200.0;
        else
            radians = v;
        return Value(Real(toAngle(radians)));
    }

    case AstOp::Transpose: {
        Value v = eval(n.args[0]);
        if (!v.isMatrix() && !v.isVector())
            throw CalcError{ ErrorKind::Dimension, QStringLiteral("transpose needs a matrix") };
        return Value::matrix(v.mat().transposed());
    }

    case AstOp::Add: case AstOp::Sub: case AstOp::Mul: case AstOp::Div:
    case AstOp::Pow: case AstOp::Permute: case AstOp::Choose: case AstOp::Polar:
    case AstOp::BitAnd: case AstOp::BitOr: case AstOp::BitXor: case AstOp::BitXnor:
        return evalBinary(n);

    case AstOp::Call:
        return evalCall(n);

    case AstOp::Sum:
    case AstOp::Product: {
        const double lo = eval(n.args[1]).d();
        const double hi = eval(n.args[2]).d();
        long long a = 0, b = 0;
        if (!isIntegral(lo, &a) || !isIntegral(hi, &b))
            throw CalcError{ ErrorKind::Argument, QStringLiteral("sigma bounds must be integers") };
        if (b < a || b - a > 100000)
            throw CalcError{ ErrorKind::Argument, QStringLiteral("sigma range out of bounds") };
        const Value saved = lookupVar(QStringLiteral("x"));
        double acc = (n.op == AstOp::Sum) ? 0.0 : 1.0;
        for (long long i = a; i <= b; ++i) {
            m_ctx.vars[QStringLiteral("x")] = Value(Real::integer(i));
            const double term = eval(n.args[0]).d();
            if (n.op == AstOp::Sum)
                acc += term;
            else
                acc *= term;
        }
        m_ctx.vars[QStringLiteral("x")] = saved;
        requireFinite(acc);
        return Value(Real(acc));
    }

    case AstOp::Integral: {
        const double a = eval(n.args[1]).d();
        const double b = eval(n.args[2]).d();
        const Value saved = lookupVar(QStringLiteral("x"));
        auto f = [&](double x) {
            m_ctx.vars[QStringLiteral("x")] = Value(Real(x));
            return eval(n.args[0]).d();
        };
        // Adaptive Gauss-Kronrod would be closer to the real thing; composite
        // Simpson with Richardson refinement is accurate enough for display.
        auto simpson = [&](int intervals) {
            const double h = (b - a) / intervals;
            double s = f(a) + f(b);
            for (int i = 1; i < intervals; ++i)
                s += f(a + i * h) * ((i % 2) ? 4.0 : 2.0);
            return s * h / 3.0;
        };
        double prev = simpson(64);
        double result = prev;
        for (int nseg = 128; nseg <= 4096; nseg *= 2) {
            result = simpson(nseg);
            if (std::fabs(result - prev) < 1e-11 * std::max(1.0, std::fabs(result)))
                break;
            prev = result;
        }
        m_ctx.vars[QStringLiteral("x")] = saved;
        requireFinite(result);
        return Value(Real(snap(result)));
    }

    case AstOp::Derivative: {
        const double x0 = eval(n.args[1]).d();
        const Value saved = lookupVar(QStringLiteral("x"));
        auto f = [&](double x) {
            m_ctx.vars[QStringLiteral("x")] = Value(Real(x));
            return eval(n.args[0]).d();
        };
        const double h = std::max(1e-5, std::fabs(x0) * 1e-5);
        // Five-point stencil: markedly better than a plain central difference.
        const double d = (-f(x0 + 2 * h) + 8 * f(x0 + h) - 8 * f(x0 - h) + f(x0 - 2 * h)) / (12 * h);
        m_ctx.vars[QStringLiteral("x")] = saved;
        requireFinite(d);
        return Value(Real(snap(d)));
    }

    case AstOp::Equality:
        throw CalcError{ ErrorKind::Syntax, QStringLiteral("'=' is not valid here") };
    }
    throw CalcError{ ErrorKind::Syntax, QStringLiteral("unsupported operation") };
}

Value Evaluator::evalBinary(const Ast &n)
{
    Value lv = eval(n.args[0]);
    Value rv = eval(n.args[1]);

    // Matrix and vector arithmetic.
    if (lv.isMatrix() || rv.isMatrix() || lv.isVector() || rv.isVector()) {
        const bool bothMat = (lv.isMatrix() || lv.isVector()) && (rv.isMatrix() || rv.isVector());
        const Matrix &A = lv.mat();
        const Matrix &B = rv.mat();
        auto wrap = [&](const Matrix &m) {
            return (lv.isVector() && (rv.isVector() || rv.isScalar())) ? Value::vector(m)
                                                                       : Value::matrix(m);
        };
        if (n.op == AstOp::Add || n.op == AstOp::Sub) {
            if (!bothMat || A.rows() != B.rows() || A.cols() != B.cols())
                throw CalcError{ ErrorKind::Dimension, QStringLiteral("matrix size mismatch") };
            Matrix m(A.rows(), A.cols());
            for (int r = 0; r < A.rows(); ++r)
                for (int c = 0; c < A.cols(); ++c)
                    m.at(r, c) = (n.op == AstOp::Add) ? A.at(r, c) + B.at(r, c)
                                                      : A.at(r, c) - B.at(r, c);
            return wrap(m);
        }
        if (n.op == AstOp::Mul) {
            if (lv.isScalar() || rv.isScalar()) {
                const double k = lv.isScalar() ? lv.d() : rv.d();
                const Matrix &M = lv.isScalar() ? B : A;
                Matrix m(M.rows(), M.cols());
                for (int r = 0; r < M.rows(); ++r)
                    for (int c = 0; c < M.cols(); ++c)
                        m.at(r, c) = M.at(r, c) * k;
                return (lv.isVector() || rv.isVector()) ? Value::vector(m) : Value::matrix(m);
            }
            if (A.cols() != B.rows())
                throw CalcError{ ErrorKind::Dimension, QStringLiteral("matrix size mismatch") };
            Matrix m(A.rows(), B.cols());
            for (int r = 0; r < A.rows(); ++r)
                for (int c = 0; c < B.cols(); ++c) {
                    double s = 0.0;
                    for (int k = 0; k < A.cols(); ++k)
                        s += A.at(r, k) * B.at(k, c);
                    m.at(r, c) = s;
                }
            return Value::matrix(m);
        }
        if (n.op == AstOp::Div && rv.isScalar()) {
            const double k = rv.d();
            if (k == 0.0)
                throw CalcError{ ErrorKind::Math, QStringLiteral("division by zero") };
            Matrix m(A.rows(), A.cols());
            for (int r = 0; r < A.rows(); ++r)
                for (int c = 0; c < A.cols(); ++c)
                    m.at(r, c) = A.at(r, c) / k;
            return wrap(m);
        }
        if (n.op == AstOp::Pow && rv.isScalar()) {
            long long k = 0;
            if (!isIntegral(rv.d(), &k))
                throw CalcError{ ErrorKind::Argument, QStringLiteral("matrix power must be an integer") };
            if (k == -1)
                return Value::matrix(A.inverted());
            if (k < 0)
                throw CalcError{ ErrorKind::Argument, QStringLiteral("unsupported matrix power") };
            if (A.rows() != A.cols())
                throw CalcError{ ErrorKind::Dimension, QStringLiteral("matrix power needs a square matrix") };
            Matrix acc(A.rows(), A.rows());
            for (int i = 0; i < A.rows(); ++i)
                acc.at(i, i) = 1.0;
            for (long long i = 0; i < k; ++i) {
                Matrix t(A.rows(), A.cols());
                for (int r = 0; r < A.rows(); ++r)
                    for (int c = 0; c < A.cols(); ++c) {
                        double s = 0.0;
                        for (int j = 0; j < A.cols(); ++j)
                            s += acc.at(r, j) * A.at(j, c);
                        t.at(r, c) = s;
                    }
                acc = t;
            }
            return Value::matrix(acc);
        }
        throw CalcError{ ErrorKind::Dimension, QStringLiteral("unsupported matrix operation") };
    }

    // Complex arithmetic.
    if (lv.isComplex() || rv.isComplex()) {
        const Cplx a = lv.c();
        const Cplx b = rv.c();
        switch (n.op) {
        case AstOp::Add: return Value::complex(a + b).simplified();
        case AstOp::Sub: return Value::complex(a - b).simplified();
        case AstOp::Mul: return Value::complex(a * b).simplified();
        case AstOp::Div:
            if (std::abs(b) == 0.0)
                throw CalcError{ ErrorKind::Math, QStringLiteral("division by zero") };
            return Value::complex(a / b).simplified();
        case AstOp::Pow: return Value::complex(std::pow(a, b)).simplified();
        case AstOp::Polar: {
            const double theta = fromAngle(rv.d());
            return Value::complex(std::polar(lv.d(), theta));
        }
        default:
            throw CalcError{ ErrorKind::Argument, QStringLiteral("operation not defined for complex values") };
        }
    }

    const Real &a = lv.real();
    const Real &b = rv.real();
    const bool exactPair = a.hasExact() && b.hasExact();

    switch (n.op) {
    case AstOp::Add: {
        const double d = a.d + b.d;
        requireFinite(d);
        return Value(Real(d, exactPair ? a.e + b.e : Exact::invalid()));
    }
    case AstOp::Sub: {
        const double d = a.d - b.d;
        requireFinite(d);
        return Value(Real(d, exactPair ? a.e - b.e : Exact::invalid()));
    }
    case AstOp::Mul: {
        const double d = a.d * b.d;
        requireFinite(d);
        return Value(Real(d, exactPair ? a.e * b.e : Exact::invalid()));
    }
    case AstOp::Div: {
        if (b.d == 0.0)
            throw CalcError{ ErrorKind::Math, QStringLiteral("division by zero") };
        const double d = a.d / b.d;
        requireFinite(d);
        return Value(Real(d, exactPair ? a.e / b.e : Exact::invalid()));
    }
    case AstOp::Pow: {
        if (a.d < 0.0) {
            long long k = 0;
            if (isIntegral(b.d, &k)) {
                const double d = std::pow(a.d, static_cast<double>(k));
                requireFinite(d);
                return Value(Real(d, a.hasExact() ? a.e.powInt(k) : Exact::invalid()));
            }
            // A fractional power of a negative base is complex.
            if (m_ctx.complexMode)
                return Value::complex(std::pow(Cplx(a.d, 0.0), Cplx(b.d, 0.0))).simplified();
            // Odd integer roots stay real: (-8)^(1/3) == -2.
            const double inv = 1.0 / b.d;
            long long kk = 0;
            if (isIntegral(inv, &kk) && (kk % 2 != 0)) {
                const double d = -std::pow(-a.d, b.d);
                requireFinite(d);
                return Value(Real(d));
            }
            throw CalcError{ ErrorKind::Math, QStringLiteral("negative base with fractional exponent") };
        }
        if (a.d == 0.0 && b.d < 0.0)
            throw CalcError{ ErrorKind::Math, QStringLiteral("division by zero") };

        Exact ex = Exact::invalid();
        if (exactPair) {
            long long k = 0;
            if (b.e.isInteger() && isIntegral(b.d, &k))
                ex = a.e.powInt(k);
            else if (b.e.isRational() && b.e.p() == 1 && b.e.s() == 2)
                ex = a.e.sqrtExact();
        }
        const double d = std::pow(a.d, b.d);
        requireFinite(d);
        if (!ex.isValid())
            ex = Exact::fromDouble(d);
        return Value(Real(d, ex));
    }
    case AstOp::Permute:
    case AstOp::Choose: {
        long long nn = 0, rr = 0;
        if (!isIntegral(a.d, &nn) || !isIntegral(b.d, &rr) || nn < 0 || rr < 0 || rr > nn)
            throw CalcError{ ErrorKind::Argument, QStringLiteral("nPr/nCr need 0 <= r <= n") };
        double acc = 1.0;
        for (long long i = 0; i < rr; ++i)
            acc *= static_cast<double>(nn - i);
        if (n.op == AstOp::Choose)
            for (long long i = 2; i <= rr; ++i)
                acc /= static_cast<double>(i);
        acc = std::round(acc);
        requireFinite(acc);
        return Value(Real(acc, Exact::fromDouble(acc)));
    }
    case AstOp::Polar:
        return Value::complex(std::polar(a.d, fromAngle(b.d)));
    case AstOp::BitAnd:
    case AstOp::BitOr:
    case AstOp::BitXor:
    case AstOp::BitXnor: {
        long long x = 0, y = 0;
        if (!isIntegral(a.d, &x) || !isIntegral(b.d, &y))
            throw CalcError{ ErrorKind::Argument, QStringLiteral("logic operators need integers") };
        long long r = 0;
        switch (n.op) {
        case AstOp::BitAnd:  r = x & y; break;
        case AstOp::BitOr:   r = x | y; break;
        case AstOp::BitXor:  r = x ^ y; break;
        default:             r = ~(x ^ y); break;
        }
        return Value(Real::integer(r));
    }
    default:
        break;
    }
    throw CalcError{ ErrorKind::Syntax, QStringLiteral("unsupported operator") };
}

Value Evaluator::evalCall(const Ast &n)
{
    const QString &f = n.name;
    const int argc = static_cast<int>(n.args.size());

    auto need = [&](int lo, int hi) {
        if (argc < lo || argc > hi)
            throw CalcError{ ErrorKind::Argument,
                             QStringLiteral("%1 takes %2 argument(s)").arg(f).arg(lo), n.pos };
    };
    auto argD = [&](int i) { return eval(n.args[i]).d(); };
    auto argV = [&](int i) { return eval(n.args[i]); };

    // --- trigonometry -------------------------------------------------------
    if (f == QLatin1String("sin") || f == QLatin1String("cos") || f == QLatin1String("tan")) {
        need(1, 1);
        Value v = argV(0);
        if (v.isComplex()) {
            const Cplx z = v.c();
            if (f == QLatin1String("sin")) return Value::complex(std::sin(z)).simplified();
            if (f == QLatin1String("cos")) return Value::complex(std::cos(z)).simplified();
            return Value::complex(std::tan(z)).simplified();
        }
        const double raw = v.d();
        const double degrees = (m_ctx.angle == AngleUnit::Deg) ? raw
                             : (m_ctx.angle == AngleUnit::Rad) ? raw * 180.0 / M_PI
                                                               : raw * 0.9;
        if (f == QLatin1String("tan")) {
            const double m = std::fmod(std::fabs(degrees), 180.0);
            if (std::fabs(m - 90.0) < 1e-9)
                throw CalcError{ ErrorKind::Math, QStringLiteral("tan is undefined here") };
        }
        Exact ex;
        if (exactTrig(f, degrees, &ex))
            return Value(Real(ex.toDouble(), ex));
        const double r = fromAngle(raw);
        const double d = (f == QLatin1String("sin")) ? std::sin(r)
                       : (f == QLatin1String("cos")) ? std::cos(r)
                                                     : std::tan(r);
        requireFinite(d);
        return Value(Real(snap(d)));
    }
    if (f == QLatin1String("asin") || f == QLatin1String("acos") || f == QLatin1String("atan")) {
        need(1, 1);
        const double v = argD(0);
        if (f != QLatin1String("atan") && (v < -1.0 || v > 1.0))
            throw CalcError{ ErrorKind::Math, QStringLiteral("argument outside [-1, 1]") };
        const double r = (f == QLatin1String("asin")) ? std::asin(v)
                       : (f == QLatin1String("acos")) ? std::acos(v)
                                                      : std::atan(v);
        return Value(Real(snap(toAngle(r))));
    }
    if (f == QLatin1String("sinh")) { need(1, 1); return Value(Real(std::sinh(argD(0)))); }
    if (f == QLatin1String("cosh")) { need(1, 1); return Value(Real(std::cosh(argD(0)))); }
    if (f == QLatin1String("tanh")) { need(1, 1); return Value(Real(std::tanh(argD(0)))); }
    if (f == QLatin1String("asinh")) { need(1, 1); return Value(Real(std::asinh(argD(0)))); }
    if (f == QLatin1String("acosh")) {
        need(1, 1);
        const double v = argD(0);
        if (v < 1.0)
            throw CalcError{ ErrorKind::Math, QStringLiteral("acosh needs an argument >= 1") };
        return Value(Real(std::acosh(v)));
    }
    if (f == QLatin1String("atanh")) {
        need(1, 1);
        const double v = argD(0);
        if (v <= -1.0 || v >= 1.0)
            throw CalcError{ ErrorKind::Math, QStringLiteral("atanh needs |x| < 1") };
        return Value(Real(std::atanh(v)));
    }

    // --- logarithms and exponentials ---------------------------------------
    if (f == QLatin1String("log")) {
        need(1, 2);
        if (argc == 2) {
            const double base = argD(0), v = argD(1);
            if (base <= 0.0 || base == 1.0 || v <= 0.0)
                throw CalcError{ ErrorKind::Math, QStringLiteral("invalid logarithm") };
            const double d = std::log(v) / std::log(base);
            return Value(Real(snap(d), Exact::fromDouble(snap(d))));
        }
        const double v = argD(0);
        if (v <= 0.0)
            throw CalcError{ ErrorKind::Math, QStringLiteral("log needs a positive argument") };
        const double d = std::log10(v);
        return Value(Real(snap(d), Exact::fromDouble(snap(d))));
    }
    if (f == QLatin1String("ln")) {
        need(1, 1);
        const double v = argD(0);
        if (v <= 0.0)
            throw CalcError{ ErrorKind::Math, QStringLiteral("ln needs a positive argument") };
        return Value(Real(std::log(v)));
    }
    if (f == QLatin1String("10^")) {
        need(1, 1);
        const double d = std::pow(10.0, argD(0));
        requireFinite(d);
        return Value(Real(d, Exact::fromDouble(d)));
    }
    if (f == QLatin1String("e^")) {
        need(1, 1);
        const double d = std::exp(argD(0));
        requireFinite(d);
        return Value(Real(d));
    }

    // --- roots ---------------------------------------------------------------
    if (f == QLatin1String("sqrt")) {
        need(1, 1);
        Value v = argV(0);
        if (v.isComplex() || (m_ctx.complexMode && v.d() < 0.0))
            return Value::complex(std::sqrt(v.c())).simplified();
        const Real &r = v.real();
        if (r.d < 0.0)
            throw CalcError{ ErrorKind::Math, QStringLiteral("square root of a negative number") };
        Exact ex = r.hasExact() ? r.e.sqrtExact() : Exact::invalid();
        return Value(Real(std::sqrt(r.d), ex));
    }
    if (f == QLatin1String("cbrt")) {
        need(1, 1);
        const double v = argD(0);
        const double d = std::cbrt(v);
        return Value(Real(snap(d), Exact::fromDouble(snap(d))));
    }
    if (f == QLatin1String("nthroot")) {
        need(2, 2);
        const double idx = argD(0);
        Value radV = argV(1);
        const Real &rad = radV.real();
        long long k = 0;
        if (!isIntegral(idx, &k) || k == 0)
            throw CalcError{ ErrorKind::Argument, QStringLiteral("root index must be a non-zero integer") };
        if (rad.d < 0.0) {
            if (k % 2 == 0)
                throw CalcError{ ErrorKind::Math, QStringLiteral("even root of a negative number") };
            const double d = -std::pow(-rad.d, 1.0 / static_cast<double>(k));
            return Value(Real(snap(d), Exact::fromDouble(snap(d))));
        }
        const double d = std::pow(rad.d, 1.0 / static_cast<double>(k));
        Exact ex = Exact::invalid();
        if (k == 2 && rad.hasExact())
            ex = rad.e.sqrtExact();
        if (!ex.isValid())
            ex = Exact::fromDouble(snap(d));
        return Value(Real(snap(d), ex));
    }

    // --- rounding and integer helpers ---------------------------------------
    if (f == QLatin1String("Abs")) {
        need(1, 1);
        Value v = argV(0);
        if (v.isComplex())
            return Value(Real(std::abs(v.c())));
        if (v.isVector() || v.isMatrix()) {
            double s = 0.0;
            const Matrix &m = v.mat();
            for (int r = 0; r < m.rows(); ++r)
                for (int c = 0; c < m.cols(); ++c)
                    s += m.at(r, c) * m.at(r, c);
            return Value(Real(std::sqrt(s)));
        }
        const Real &r = v.real();
        return Value(Real(std::fabs(r.d), r.hasExact() ? (r.e.toDouble() < 0 ? -r.e : r.e)
                                                       : Exact::invalid()));
    }
    if (f == QLatin1String("Int")) { need(1, 1); return Value(Real(std::trunc(argD(0)))); }
    if (f == QLatin1String("Intg")) { need(1, 1); return Value(Real(std::floor(argD(0)))); }
    if (f == QLatin1String("Rnd")) { need(1, 1); return Value(Real(argD(0))); }
    if (f == QLatin1String("GCD")) {
        need(2, 2);
        long long x = 0, y = 0;
        if (!isIntegral(argD(0), &x) || !isIntegral(argD(1), &y))
            throw CalcError{ ErrorKind::Argument, QStringLiteral("GCD needs integers") };
        return Value(Real::integer(gcdll(x, y)));
    }
    if (f == QLatin1String("LCM")) {
        need(2, 2);
        long long x = 0, y = 0;
        if (!isIntegral(argD(0), &x) || !isIntegral(argD(1), &y))
            throw CalcError{ ErrorKind::Argument, QStringLiteral("LCM needs integers") };
        const long long g = gcdll(x, y);
        if (g == 0)
            return Value(Real::integer(0));
        return Value(Real::integer(std::llabs(x / g * y)));
    }
    if (f == QLatin1String("RanInt")) {
        need(2, 2);
        long long lo = 0, hi = 0;
        if (!isIntegral(argD(0), &lo) || !isIntegral(argD(1), &hi) || hi < lo)
            throw CalcError{ ErrorKind::Argument, QStringLiteral("RanInt needs lo <= hi") };
        return Value(Real::integer(QRandomGenerator::global()->bounded(
                static_cast<qint64>(lo), static_cast<qint64>(hi) + 1)));
    }

    // --- complex helpers ------------------------------------------------------
    if (f == QLatin1String("Arg")) {
        need(1, 1);
        return Value(Real(snap(toAngle(std::arg(argV(0).c())))));
    }
    if (f == QLatin1String("Conjg")) {
        need(1, 1);
        return Value::complex(std::conj(argV(0).c())).simplified();
    }
    if (f == QLatin1String("Real")) { need(1, 1); return Value(Real(argV(0).c().real())); }
    if (f == QLatin1String("Imag")) { need(1, 1); return Value(Real(argV(0).c().imag())); }

    // --- coordinate conversion -------------------------------------------------
    if (f == QLatin1String("Pol")) {
        need(2, 2);
        const double x = argD(0), y = argD(1);
        const double r = std::hypot(x, y);
        const double theta = snap(toAngle(std::atan2(y, x)));
        m_ctx.vars[QStringLiteral("x")] = Value(Real(r));
        m_ctx.vars[QStringLiteral("y")] = Value(Real(theta));
        return Value(Real(r));
    }
    if (f == QLatin1String("Rec")) {
        need(2, 2);
        const double r = argD(0);
        const double theta = fromAngle(argD(1));
        const double x = snap(r * std::cos(theta));
        const double y = snap(r * std::sin(theta));
        m_ctx.vars[QStringLiteral("x")] = Value(Real(x));
        m_ctx.vars[QStringLiteral("y")] = Value(Real(y));
        return Value(Real(x));
    }

    // --- matrix helpers ----------------------------------------------------------
    if (f == QLatin1String("det")) {
        need(1, 1);
        return Value(Real(argV(0).mat().determinant()));
    }
    if (f == QLatin1String("Trn")) {
        need(1, 1);
        return Value::matrix(argV(0).mat().transposed());
    }
    if (f == QLatin1String("Inverse")) {
        need(1, 1);
        return Value::matrix(argV(0).mat().inverted());
    }

    throw CalcError{ ErrorKind::Syntax, QStringLiteral("unknown function '%1'").arg(f), n.pos };
}

} // namespace fx
