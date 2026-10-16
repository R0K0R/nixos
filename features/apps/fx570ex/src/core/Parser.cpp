#include "Parser.h"

#include <QSet>
#include <cmath>

namespace fx {

Parser::Parser(const Node *row)
{
    if (row && row->isRow())
        m_items = row->children();
}

AstP Parser::parseRow(const Node *row)
{
    Parser p(row);
    return p.parse();
}

AstP Parser::parse()
{
    if (m_items.isEmpty())
        throw CalcError{ ErrorKind::Syntax, QStringLiteral("empty expression"), 0 };
    AstP e = parseEquality();
    if (!atEnd())
        fail(QStringLiteral("unexpected input"));
    return e;
}

const Node *Parser::peek(int ahead) const
{
    const int i = m_pos + ahead;
    return (i >= 0 && i < m_items.size()) ? m_items.at(i) : nullptr;
}

const Node *Parser::advance()
{
    return atEnd() ? nullptr : m_items.at(m_pos++);
}

bool Parser::matchCode(const QString &code)
{
    const Node *n = peek();
    if (n && n->isAtom() && n->code() == code) {
        ++m_pos;
        return true;
    }
    return false;
}

void Parser::fail(const QString &detail) const
{
    throw CalcError{ ErrorKind::Syntax, detail, m_pos };
}

/*
  The outermost level: `left = right`, entered with ALPHA+CALC.

  An equation is not a calculation, so nothing evaluates it -- Evaluator throws
  Syntax ERROR on AstOp::Equality, which is what the real unit does when you
  press `=` on one. SOLVE is the consumer: it takes the two sides and looks for
  a root of left - right.
*/
AstP Parser::parseEquality()
{
    AstP left = parseStore();
    if (matchCode(QStringLiteral("="))) {
        AstP right = parseStore();
        return Ast::binary(AstOp::Equality, left, right);
    }
    return left;
}

// --- level 12: A -> X ------------------------------------------------------

AstP Parser::parseStore()
{
    AstP left = parseLogicOr();
    if (matchCode(QStringLiteral("->"))) {
        const Node *target = advance();
        if (!target || !target->isAtom() || !atomIsValue(target->code()))
            fail(QStringLiteral("STO needs a variable"));
        AstP a = Ast::make(AstOp::Store);
        a->name = target->code();
        a->args = { left };
        return a;
    }
    return left;
}

// --- levels 10/11: logical operators ---------------------------------------

AstP Parser::parseLogicOr()
{
    AstP left = parseLogicAnd();
    while (const Node *n = peek()) {
        if (!n->isAtom())
            break;
        AstOp op;
        if (n->code() == QLatin1String("or"))
            op = AstOp::BitOr;
        else if (n->code() == QLatin1String("xor"))
            op = AstOp::BitXor;
        else if (n->code() == QLatin1String("xnor"))
            op = AstOp::BitXnor;
        else
            break;
        ++m_pos;
        left = Ast::binary(op, left, parseLogicAnd());
    }
    return left;
}

AstP Parser::parseLogicAnd()
{
    AstP left = parseAddSub();
    while (peek() && peek()->isAtom() && peek()->code() == QLatin1String("and")) {
        ++m_pos;
        left = Ast::binary(AstOp::BitAnd, left, parseAddSub());
    }
    return left;
}

// --- level 9: + - ----------------------------------------------------------

AstP Parser::parseAddSub()
{
    AstP left = parseMulDiv();
    while (const Node *n = peek()) {
        if (!n->isAtom())
            break;
        if (n->code() == QLatin1String("+")) {
            ++m_pos;
            left = Ast::binary(AstOp::Add, left, parseMulDiv());
        } else if (n->code() == QLatin1String("-")) {
            ++m_pos;
            left = Ast::binary(AstOp::Sub, left, parseMulDiv());
        } else {
            break;
        }
    }
    return left;
}

// --- level 8: x / and implicit multiplication before "(" or a function -----

AstP Parser::parseMulDiv()
{
    AstP left = parsePermute();
    for (;;) {
        const Node *n = peek();
        if (!n)
            break;
        if (n->isAtom() && n->code() == QLatin1String("*")) {
            ++m_pos;
            left = Ast::binary(AstOp::Mul, left, parsePermute());
            continue;
        }
        if (n->isAtom() && n->code() == QLatin1String("/")) {
            ++m_pos;
            left = Ast::binary(AstOp::Div, left, parsePermute());
            continue;
        }
        // 2(3+4) and 2sin(30) multiply at ordinary x precedence, which is why
        // 6/2(1+2) evaluates to 9 on a ClassWiz.
        if (n->isAtom() && (n->code() == QLatin1String("(") || atomIsFunction(n->code()))) {
            left = Ast::binary(AstOp::Mul, left, parsePermute());
            continue;
        }
        break;
    }
    return left;
}

// --- level 7: nPr, nCr, angle ----------------------------------------------

AstP Parser::parsePermute()
{
    AstP left = parseImplicit();
    while (const Node *n = peek()) {
        if (!n->isAtom())
            break;
        AstOp op;
        if (n->code() == QLatin1String("nPr"))
            op = AstOp::Permute;
        else if (n->code() == QLatin1String("nCr"))
            op = AstOp::Choose;
        else if (n->code() == QLatin1String("angle"))
            op = AstOp::Polar;
        else
            break;
        ++m_pos;
        left = Ast::binary(op, left, parseImplicit());
    }
    return left;
}

// --- level 6: abbreviated multiplication in front of pi, e, variables ------

AstP Parser::parseImplicit()
{
    AstP left = parseUnary();
    while (const Node *n = peek()) {
        if (!startsTightFactor(n))
            break;
        left = Ast::binary(AstOp::Mul, left, parseUnary());
    }
    return left;
}

// --- level 4: prefix minus -------------------------------------------------

AstP Parser::parseUnary()
{
    const Node *n = peek();
    if (n && n->isAtom() && (n->code() == QLatin1String("neg") || n->code() == QLatin1String("-"))) {
        ++m_pos;
        return Ast::unary(AstOp::Neg, parseUnary());
    }
    return parsePostfix();
}

// --- level 2: postfix functions, powers, roots ------------------------------

AstP Parser::parsePostfix()
{
    AstP v = parsePrimary();
    for (;;) {
        const Node *n = peek();
        if (!n)
            break;
        if (n->kind() == NodeKind::Power) {
            ++m_pos;
            v = Ast::binary(AstOp::Pow, v, Parser::parseRow(n->arg(0)));
            continue;
        }
        if (!n->isAtom())
            break;
        const QString &c = n->code();
        if (c == QLatin1String("sqr")) {
            ++m_pos;
            v = Ast::binary(AstOp::Pow, v, Ast::number(2.0, Exact::rational(2)));
        } else if (c == QLatin1String("cube")) {
            ++m_pos;
            v = Ast::binary(AstOp::Pow, v, Ast::number(3.0, Exact::rational(3)));
        } else if (c == QLatin1String("inv")) {
            ++m_pos;
            v = Ast::binary(AstOp::Pow, v, Ast::number(-1.0, Exact::rational(-1)));
        } else if (c == QLatin1String("!")) {
            ++m_pos;
            v = Ast::unary(AstOp::Factorial, v);
        } else if (c == QLatin1String("pct")) {
            ++m_pos;
            v = Ast::unary(AstOp::Percent, v);
        } else if (c == QLatin1String("T")) {
            ++m_pos;
            v = Ast::unary(AstOp::Transpose, v);
        } else if (c == QLatin1String("deg") || c == QLatin1String("rad") || c == QLatin1String("grad")) {
            ++m_pos;
            AstP a = Ast::unary(AstOp::DegMinSec, v);
            a->name = c;
            v = a;
        } else {
            break;
        }
    }
    return v;
}

// --- primaries --------------------------------------------------------------

bool Parser::startsFactor(const Node *n) const
{
    if (!n)
        return false;
    if (n->isStructure())
        return n->kind() != NodeKind::Power;
    if (!n->isAtom())
        return false;
    const QString &c = n->code();
    if (atomIsDigit(c) || c == QLatin1String(".") || atomIsValue(c) || atomIsFunction(c))
        return true;
    return c == QLatin1String("(") || c == QLatin1String("neg");
}

bool Parser::startsTightFactor(const Node *n) const
{
    if (!n)
        return false;
    if (n->isStructure())
        return n->kind() != NodeKind::Power;
    if (!n->isAtom())
        return false;
    // Only constants and variables bind tighter than x/ -- "2pi" is one term,
    // while "2(1+2)" and "2sin(30)" are handled at ordinary x precedence.
    return atomIsValue(n->code());
}

AstP Parser::parsePrimary()
{
    const Node *n = peek();
    if (!n)
        fail(QStringLiteral("expression ended early"));

    if (n->isStructure())
        return parseStructure(advance());

    if (!n->isAtom())
        fail(QStringLiteral("unexpected node"));

    const QString c = n->code();
    const int start = m_pos;

    if (atomIsDigit(c) || c == QLatin1String("."))
        return parseNumber();

    if (c == QLatin1String("(")) {
        ++m_pos;
        AstP inner = parseStore();
        matchCode(QStringLiteral(")")); // an omitted closing paren is legal
        return inner;
    }

    if (atomIsFunction(c)) {
        ++m_pos;
        AstP call = Ast::make(AstOp::Call);
        call->name = c.left(c.size() - 1);
        call->pos = start;
        call->args = parseCallArgs();
        return call;
    }

    if (atomIsValue(c)) {
        ++m_pos;
        AstP a = Ast::make(c == QLatin1String("pi") || c == QLatin1String("e")
                                   || c == QLatin1String("i") || c == QLatin1String("Ran#")
                           ? AstOp::Constant
                           : AstOp::Variable);
        a->name = c;
        a->pos = start;
        return a;
    }

    fail(QStringLiteral("unexpected '%1'").arg(atomGlyph(c)));
}

std::vector<AstP> Parser::parseCallArgs()
{
    std::vector<AstP> args;
    if (atEnd() || (peek()->isAtom() && peek()->code() == QLatin1String(")"))) {
        matchCode(QStringLiteral(")"));
        return args;
    }
    for (;;) {
        args.push_back(parseStore());
        if (matchCode(QStringLiteral(",")))
            continue;
        matchCode(QStringLiteral(")"));
        break;
    }
    return args;
}

AstP Parser::parseNumber()
{
    QString digits;
    bool seenDot = false;
    const int start = m_pos;

    while (const Node *n = peek()) {
        if (!n->isAtom())
            break;
        const QString &c = n->code();
        if (atomIsDigit(c)) {
            digits += c;
            ++m_pos;
        } else if (c == QLatin1String(".") && !seenDot) {
            seenDot = true;
            digits += QLatin1Char('.');
            ++m_pos;
        } else {
            break;
        }
    }
    if (digits.isEmpty() || digits == QLatin1String("."))
        fail(QStringLiteral("malformed number"));

    int exponent = 0;
    bool hasExponent = false;
    if (peek() && peek()->isAtom() && peek()->code() == QLatin1String("E")) {
        const int save = m_pos;
        ++m_pos;
        bool negExp = false;
        if (peek() && peek()->isAtom()
            && (peek()->code() == QLatin1String("neg") || peek()->code() == QLatin1String("-"))) {
            negExp = true;
            ++m_pos;
        }
        QString ed;
        while (peek() && peek()->isAtom() && atomIsDigit(peek()->code())) {
            ed += peek()->code();
            ++m_pos;
        }
        if (ed.isEmpty()) {
            m_pos = save; // a bare "E" is a syntax error, reported by the caller
        } else {
            exponent = ed.left(3).toInt() * (negExp ? -1 : 1);
            hasExponent = true;
        }
    }

    // Exact literal: integer digits over a power of ten, then scaled by 10^exp.
    const int dot = digits.indexOf(QLatin1Char('.'));
    QString mantissaDigits = digits;
    int fracLen = 0;
    if (dot >= 0) {
        fracLen = digits.size() - dot - 1;
        mantissaDigits.remove(dot, 1);
    }
    bool okLL = false;
    const long long mantissa = mantissaDigits.toLongLong(&okLL);
    Exact ex;
    if (okLL && mantissaDigits.size() <= 15) {
        int scale = exponent - fracLen;
        ex = Exact::rational(mantissa, 1);
        while (ex.isValid() && scale > 0) {
            ex = ex * Exact::rational(10);
            --scale;
        }
        while (ex.isValid() && scale < 0) {
            ex = ex / Exact::rational(10);
            ++scale;
        }
    }

    double value = digits.toDouble();
    if (hasExponent)
        value *= std::pow(10.0, exponent);

    AstP a = Ast::number(value, ex);
    a->pos = start;
    return a;
}

AstP Parser::parseStructure(const Node *n)
{
    switch (n->kind()) {
    case NodeKind::Frac:
        return Ast::binary(AstOp::Div, parseRow(n->arg(0)), parseRow(n->arg(1)));
    case NodeKind::MixedFrac: {
        AstP whole = parseRow(n->arg(0));
        AstP frac = Ast::binary(AstOp::Div, parseRow(n->arg(1)), parseRow(n->arg(2)));
        // A negative integer part applies to the whole mixed number.
        AstP sum = Ast::binary(AstOp::Add, whole, frac);
        sum->name = QStringLiteral("mixed");
        return sum;
    }
    case NodeKind::Sqrt:
        return Ast::binary(AstOp::Pow, parseRow(n->arg(0)),
                           Ast::number(0.5, Exact::rational(1, 2)));
    case NodeKind::Root: {
        AstP index = parseRow(n->arg(0));
        AstP rad = parseRow(n->arg(1));
        AstP call = Ast::make(AstOp::Call);
        call->name = QStringLiteral("nthroot");
        call->args = { index, rad };
        return call;
    }
    case NodeKind::LogBase: {
        AstP call = Ast::make(AstOp::Call);
        call->name = QStringLiteral("log");
        call->args = { parseRow(n->arg(0)), parseRow(n->arg(1)) };
        return call;
    }
    case NodeKind::Abs: {
        AstP call = Ast::make(AstOp::Call);
        call->name = QStringLiteral("Abs");
        call->args = { parseRow(n->arg(0)) };
        return call;
    }
    case NodeKind::Sum:
    case NodeKind::Product: {
        AstP a = Ast::make(n->kind() == NodeKind::Sum ? AstOp::Sum : AstOp::Product);
        a->args = { parseRow(n->arg(0)), parseRow(n->arg(1)), parseRow(n->arg(2)) };
        return a;
    }
    case NodeKind::Integral: {
        AstP a = Ast::make(AstOp::Integral);
        a->args = { parseRow(n->arg(0)), parseRow(n->arg(1)), parseRow(n->arg(2)) };
        return a;
    }
    case NodeKind::Derivative: {
        AstP a = Ast::make(AstOp::Derivative);
        a->args = { parseRow(n->arg(0)), parseRow(n->arg(1)) };
        return a;
    }
    case NodeKind::Recurring: {
        // 0.[3] == 3/9; the vinculum digits repeat immediately after the point.
        const QString digits = n->arg(0)->toLinear();
        long long num = digits.toLongLong();
        long long den = 0;
        for (int i = 0; i < digits.size(); ++i)
            den = den * 10 + 9;
        if (den == 0)
            den = 1;
        return Ast::number(static_cast<double>(num) / static_cast<double>(den),
                           Exact::rational(num, den));
    }
    default:
        break;
    }
    throw CalcError{ ErrorKind::Syntax, QStringLiteral("unsupported structure") };
}

} // namespace fx
