#include "Format.h"

#include <QStringList>
#include <cmath>

namespace fx {

namespace {

constexpr int kSignificantDigits = 10;

QString stripTrailingZeros(QString s)
{
    if (!s.contains(QLatin1Char('.')))
        return s;
    while (s.endsWith(QLatin1Char('0')))
        s.chop(1);
    if (s.endsWith(QLatin1Char('.')))
        s.chop(1);
    return s;
}

QString groupThousands(const QString &s)
{
    const int dot = s.indexOf(QLatin1Char('.'));
    QString intPart = dot < 0 ? s : s.left(dot);
    const QString rest = dot < 0 ? QString() : s.mid(dot);
    QString sign;
    if (intPart.startsWith(QLatin1Char('-'))) {
        sign = QStringLiteral("-");
        intPart.remove(0, 1);
    }
    QString out;
    int count = 0;
    for (int i = intPart.size() - 1; i >= 0; --i) {
        out.prepend(intPart.at(i));
        if (++count % 3 == 0 && i > 0)
            out.prepend(QLatin1Char(','));
    }
    return sign + out + rest;
}

// "1.234x10^-5" using the superscript glyphs the display renders.
QString withExponent(const QString &mantissa, int exponent)
{
    return mantissa + QStringLiteral("×10^") + QString::number(exponent);
}

} // namespace

QString formatNumber(double value, const FormatOptions &opt)
{
    if (std::isnan(value))
        return QStringLiteral("Math ERROR");
    if (std::isinf(value))
        return value > 0 ? QStringLiteral("∞") : QStringLiteral("-∞");
    if (value == 0.0)
        value = 0.0; // normalise -0

    QString out;
    switch (opt.format) {
    case DisplayFormat::Fix: {
        out = QString::number(value, 'f', opt.digits);
        if (out == QLatin1String("-0") || out.startsWith(QLatin1String("-0.")) ) {
            bool allZero = true;
            for (QChar ch : out)
                if (ch.isDigit() && ch != QLatin1Char('0'))
                    allZero = false;
            if (allZero)
                out.remove(0, 1);
        }
        break;
    }
    case DisplayFormat::Sci: {
        const int digits = qBound(1, opt.digits, 10);
        out = QString::number(value, 'e', digits - 1);
        const int epos = out.indexOf(QLatin1Char('e'));
        const QString mant = out.left(epos);
        const int exp = out.mid(epos + 1).toInt();
        out = withExponent(mant, exp);
        break;
    }
    case DisplayFormat::Eng: {
        if (value == 0.0) {
            out = QStringLiteral("0");
            break;
        }
        int exp = static_cast<int>(std::floor(std::log10(std::fabs(value))));
        int eng = static_cast<int>(std::floor(exp / 3.0)) * 3;
        double mant = value / std::pow(10.0, eng);
        out = stripTrailingZeros(QString::number(mant, 'f', 6));
        if (eng != 0)
            out = withExponent(out, eng);
        break;
    }
    case DisplayFormat::Norm1:
    case DisplayFormat::Norm2: {
        const double a = std::fabs(value);
        const double lowerBound = (opt.format == DisplayFormat::Norm1) ? 1e-2 : 1e-9;
        const bool useExp = (a != 0.0) && (a < lowerBound || a >= 1e10);
        if (useExp) {
            QString s = QString::number(value, 'e', kSignificantDigits - 1);
            const int epos = s.indexOf(QLatin1Char('e'));
            QString mant = stripTrailingZeros(s.left(epos));
            const int exp = s.mid(epos + 1).toInt();
            out = withExponent(mant, exp);
        } else {
            out = stripTrailingZeros(QString::number(value, 'g', kSignificantDigits));
            if (out.contains(QLatin1Char('e'))) { // 'g' fell back to exponential
                const int epos = out.indexOf(QLatin1Char('e'));
                out = withExponent(stripTrailingZeros(out.left(epos)), out.mid(epos + 1).toInt());
            }
        }
        break;
    }
    }

    if (opt.thousandsSeparator && !out.contains(QStringLiteral("10^")))
        out = groupThousands(out);
    return out;
}

QString formatValue(const Value &v, const FormatOptions &opt)
{
    switch (v.type()) {
    case Value::Type::Real:
        return formatNumber(v.real().d, opt);

    case Value::Type::Complex: {
        const Cplx z = v.c();
        const QString re = formatNumber(z.real(), opt);
        if (std::fabs(z.imag()) < 1e-13)
            return re;
        const double im = z.imag();
        const QString imStr = formatNumber(std::fabs(im), opt);
        const QString sign = im < 0 ? QStringLiteral("−") : QStringLiteral("+");
        const QString imPart = (imStr == QLatin1String("1")) ? QStringLiteral("i")
                                                             : imStr + QStringLiteral("i");
        if (std::fabs(z.real()) < 1e-13)
            return (im < 0 ? QStringLiteral("−") : QString()) + imPart;
        return re + sign + imPart;
    }

    case Value::Type::Vector:
    case Value::Type::Matrix: {
        const Matrix &m = v.mat();
        QStringList rows;
        for (int r = 0; r < m.rows(); ++r) {
            QStringList cells;
            for (int c = 0; c < m.cols(); ++c)
                cells << formatNumber(m.at(r, c), opt);
            rows << QStringLiteral("[") + cells.join(QStringLiteral(" ")) + QStringLiteral("]");
        }
        return QStringLiteral("[") + rows.join(QString()) + QStringLiteral("]");
    }
    }
    return QString();
}

} // namespace fx
