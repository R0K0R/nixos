#pragma once
#include "Exact.h"

#include <QString>
#include <memory>
#include <vector>

namespace fx {

enum class AstOp {
    Number,     // literal, `exact` carries the typed digits exactly
    Variable,   // name
    Constant,   // pi, e, i, Ran#
    Add, Sub, Mul, Div, Pow,
    Neg,
    Call,       // name + args
    Factorial,
    Percent,
    DegMinSec,  // value tagged with a unit suffix: deg / rad / grad
    Permute,    // nPr
    Choose,     // nCr
    Polar,      // r angle theta
    Transpose,
    Store,      // value -> variable
    BitAnd, BitOr, BitXor, BitXnor,
    Sum, Product, Integral, Derivative,
    Equality    // left = right, for Solve / equation input
};

struct Ast;
using AstP = std::shared_ptr<Ast>;

struct Ast {
    AstOp op = AstOp::Number;
    double num = 0.0;
    Exact exact;
    QString name;              // variable / function / unit suffix
    std::vector<AstP> args;
    int pos = -1;              // child index in the source row, for error cursors

    static AstP make(AstOp op) { auto a = std::make_shared<Ast>(); a->op = op; return a; }
    static AstP number(double v, const Exact &e)
    {
        auto a = make(AstOp::Number);
        a->num = v;
        a->exact = e;
        return a;
    }
    static AstP binary(AstOp op, AstP l, AstP r)
    {
        auto a = make(op);
        a->args = { std::move(l), std::move(r) };
        return a;
    }
    static AstP unary(AstOp op, AstP v)
    {
        auto a = make(op);
        a->args = { std::move(v) };
        return a;
    }
};

} // namespace fx
