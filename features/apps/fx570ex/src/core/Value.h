#pragma once
#include "Exact.h"

#include <QString>
#include <QVector>
#include <complex>

namespace fx {

enum class ErrorKind {
    None,
    Syntax,
    Math,
    Stack,
    Argument,
    Dimension,
    Variable,
    CannotSolve,
    Range,
    Time
};

struct CalcError {
    ErrorKind kind = ErrorKind::Syntax;
    QString detail;
    int position = -1; // index into the token stream, for the "go to error" cursor

    QString title() const;
};

// A real scalar that remembers its exact form whenever one survives.
struct Real {
    double d = 0.0;
    Exact e;

    Real() = default;
    Real(double v) : d(v) { }                                  // NOLINT(google-explicit-constructor)
    Real(double v, const Exact &ex) : d(v), e(ex) { }
    static Real fromExact(const Exact &ex) { return Real(ex.toDouble(), ex); }
    static Real integer(long long v) { return Real(static_cast<double>(v), Exact::rational(v)); }

    bool hasExact() const { return e.isValid(); }
    void dropExact() { e = Exact::invalid(); }
};

using Cplx = std::complex<double>;

class Matrix {
public:
    Matrix() = default;
    Matrix(int rows, int cols) : m_rows(rows), m_cols(cols), m_data(rows * cols, 0.0) { }

    int rows() const { return m_rows; }
    int cols() const { return m_cols; }
    bool isEmpty() const { return m_rows == 0 || m_cols == 0; }

    double at(int r, int c) const { return m_data.at(r * m_cols + c); }
    double &at(int r, int c) { return m_data[r * m_cols + c]; }

    void resize(int rows, int cols)
    {
        m_rows = rows;
        m_cols = cols;
        m_data.assign(rows * cols, 0.0);
    }

    Matrix transposed() const;
    double determinant() const;   // throws CalcError on non-square
    Matrix inverted() const;      // throws CalcError when singular

private:
    int m_rows = 0;
    int m_cols = 0;
    QVector<double> m_data;
};

class Value {
public:
    enum class Type { Real, Complex, Matrix, Vector };

    Value() : m_type(Type::Real) { }
    Value(const Real &r) : m_type(Type::Real), m_real(r) { }   // NOLINT(google-explicit-constructor)
    Value(double d) : m_type(Type::Real), m_real(d) { }        // NOLINT(google-explicit-constructor)
    static Value complex(const Cplx &c);
    static Value matrix(const Matrix &m);
    static Value vector(const Matrix &m); // 1 x n row used as a vector

    Type type() const { return m_type; }
    bool isReal() const { return m_type == Type::Real; }
    bool isComplex() const { return m_type == Type::Complex; }
    bool isMatrix() const { return m_type == Type::Matrix; }
    bool isVector() const { return m_type == Type::Vector; }
    bool isScalar() const { return m_type == Type::Real || m_type == Type::Complex; }

    const Real &real() const { return m_real; }
    Real &real() { return m_real; }
    double d() const;
    Cplx c() const;
    const Matrix &mat() const { return m_mat; }
    Matrix &mat() { return m_mat; }

    // Demotes a complex value with a negligible imaginary part back to real.
    Value simplified() const;

private:
    Type m_type = Type::Real;
    Real m_real;
    Cplx m_cplx;
    Matrix m_mat;
};

} // namespace fx
