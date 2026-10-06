#include "Value.h"

#include <QCoreApplication>
#include <cmath>

namespace fx {

QString CalcError::title() const
{
    switch (kind) {
    case ErrorKind::None:        return QStringLiteral("");
    case ErrorKind::Syntax:      return QStringLiteral("Syntax ERROR");
    case ErrorKind::Math:        return QStringLiteral("Math ERROR");
    case ErrorKind::Stack:       return QStringLiteral("Stack ERROR");
    case ErrorKind::Argument:    return QStringLiteral("Argument ERROR");
    case ErrorKind::Dimension:   return QStringLiteral("Dimension ERROR");
    case ErrorKind::Variable:    return QStringLiteral("Variable ERROR");
    case ErrorKind::CannotSolve: return QStringLiteral("Can't Solve");
    case ErrorKind::Range:       return QStringLiteral("Range ERROR");
    case ErrorKind::Time:        return QStringLiteral("Time Out");
    }
    return QStringLiteral("ERROR");
}

Matrix Matrix::transposed() const
{
    Matrix t(m_cols, m_rows);
    for (int r = 0; r < m_rows; ++r)
        for (int c = 0; c < m_cols; ++c)
            t.at(c, r) = at(r, c);
    return t;
}

double Matrix::determinant() const
{
    if (m_rows != m_cols || m_rows == 0)
        throw CalcError{ ErrorKind::Dimension, QStringLiteral("determinant needs a square matrix") };

    const int n = m_rows;
    QVector<double> a = m_data;
    double det = 1.0;
    for (int col = 0; col < n; ++col) {
        int pivot = col;
        for (int r = col + 1; r < n; ++r)
            if (std::fabs(a[r * n + col]) > std::fabs(a[pivot * n + col]))
                pivot = r;
        if (std::fabs(a[pivot * n + col]) < 1e-300)
            return 0.0;
        if (pivot != col) {
            for (int c = 0; c < n; ++c)
                std::swap(a[pivot * n + c], a[col * n + c]);
            det = -det;
        }
        det *= a[col * n + col];
        const double inv = 1.0 / a[col * n + col];
        for (int r = col + 1; r < n; ++r) {
            const double f = a[r * n + col] * inv;
            if (f == 0.0)
                continue;
            for (int c = col; c < n; ++c)
                a[r * n + c] -= f * a[col * n + c];
        }
    }
    return det;
}

Matrix Matrix::inverted() const
{
    if (m_rows != m_cols || m_rows == 0)
        throw CalcError{ ErrorKind::Dimension, QStringLiteral("inverse needs a square matrix") };

    const int n = m_rows;
    QVector<double> a = m_data;
    Matrix inv(n, n);
    for (int i = 0; i < n; ++i)
        inv.at(i, i) = 1.0;

    for (int col = 0; col < n; ++col) {
        int pivot = col;
        for (int r = col + 1; r < n; ++r)
            if (std::fabs(a[r * n + col]) > std::fabs(a[pivot * n + col]))
                pivot = r;
        if (std::fabs(a[pivot * n + col]) < 1e-12)
            throw CalcError{ ErrorKind::Math, QStringLiteral("singular matrix") };
        if (pivot != col) {
            for (int c = 0; c < n; ++c) {
                std::swap(a[pivot * n + c], a[col * n + c]);
                std::swap(inv.at(pivot, c), inv.at(col, c));
            }
        }
        const double p = a[col * n + col];
        for (int c = 0; c < n; ++c) {
            a[col * n + c] /= p;
            inv.at(col, c) /= p;
        }
        for (int r = 0; r < n; ++r) {
            if (r == col)
                continue;
            const double f = a[r * n + col];
            if (f == 0.0)
                continue;
            for (int c = 0; c < n; ++c) {
                a[r * n + c] -= f * a[col * n + c];
                inv.at(r, c) -= f * inv.at(col, c);
            }
        }
    }
    return inv;
}

Value Value::complex(const Cplx &c)
{
    Value v;
    v.m_type = Type::Complex;
    v.m_cplx = c;
    return v;
}

Value Value::matrix(const Matrix &m)
{
    Value v;
    v.m_type = Type::Matrix;
    v.m_mat = m;
    return v;
}

Value Value::vector(const Matrix &m)
{
    Value v;
    v.m_type = Type::Vector;
    v.m_mat = m;
    return v;
}

double Value::d() const
{
    switch (m_type) {
    case Type::Real:
        return m_real.d;
    case Type::Complex:
        if (std::fabs(m_cplx.imag()) > 1e-12)
            throw CalcError{ ErrorKind::Math, QStringLiteral("complex value in a real context") };
        return m_cplx.real();
    default:
        throw CalcError{ ErrorKind::Dimension, QStringLiteral("expected a scalar") };
    }
}

Cplx Value::c() const
{
    switch (m_type) {
    case Type::Real:
        return Cplx(m_real.d, 0.0);
    case Type::Complex:
        return m_cplx;
    default:
        throw CalcError{ ErrorKind::Dimension, QStringLiteral("expected a scalar") };
    }
}

Value Value::simplified() const
{
    if (m_type != Type::Complex)
        return *this;
    const double im = m_cplx.imag();
    const double re = m_cplx.real();
    if (std::fabs(im) <= 1e-13 * std::max(1.0, std::fabs(re)))
        return Value(Real(re));
    return *this;
}

} // namespace fx
