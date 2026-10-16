#pragma once
#include "Ast.h"
#include "Value.h"

#include <QHash>
#include <QString>

namespace fx {

enum class AngleUnit { Deg, Rad, Gra };

struct Context {
    AngleUnit angle = AngleUnit::Deg;
    bool complexMode = false;
    QHash<QString, Value> vars;   // A..F, x, y, z, M, Ans, PreAns
    int depth = 0;                // recursion guard for Stack ERROR
};

class Evaluator {
public:
    explicit Evaluator(Context &ctx) : m_ctx(ctx) { }

    Value eval(const AstP &node);

private:
    Value evalCall(const Ast &n);
    Value evalBinary(const Ast &n);
    Value lookupVar(const QString &name) const;

    double toAngle(double radians) const;   // radians -> current unit
    double fromAngle(double v) const;       // current unit -> radians

    Context &m_ctx;
};

double factorial(double n);

} // namespace fx
