#pragma once
#include "Ast.h"
#include "Node.h"
#include "Value.h"

namespace fx {

// Turns an editor Row into an AST following the fx-570EX calculation priority
// table (manual section "Calculation Priority Sequence").  Throws CalcError
// with the offending child index on malformed input.
class Parser {
public:
    explicit Parser(const Node *row);

    AstP parse();                 // whole row, must be fully consumed
    static AstP parseRow(const Node *row);

private:
    const Node *peek(int ahead = 0) const;
    const Node *advance();
    bool atEnd() const { return m_pos >= m_items.size(); }
    bool matchCode(const QString &code);
    [[noreturn]] void fail(const QString &detail) const;

    AstP parseEquality();
    AstP parseStore();
    AstP parseLogicOr();
    AstP parseLogicAnd();
    AstP parseAddSub();
    AstP parseMulDiv();
    AstP parsePermute();
    AstP parseImplicit();
    AstP parseUnary();
    AstP parsePostfix();
    AstP parsePrimary();
    AstP parseNumber();
    AstP parseStructure(const Node *n);
    std::vector<AstP> parseCallArgs();

    bool startsFactor(const Node *n) const;
    bool startsTightFactor(const Node *n) const;

    QVector<Node *> m_items;
    int m_pos = 0;
};

} // namespace fx
