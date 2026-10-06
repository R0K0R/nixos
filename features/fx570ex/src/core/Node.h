#pragma once
#include <QString>
#include <QVector>
#include <memory>
#include <vector>

namespace fx {

// ---------------------------------------------------------------------------
// Editable "natural textbook" expression tree.
//
// Everything the user types lives in this tree.  A Row is a horizontal run of
// children; the structural kinds (Frac, Sqrt, Power, ...) own their own Rows so
// that the display can stack them the way a ClassWiz does and the cursor can
// walk into them.  Atoms are leaves holding a canonical code (see codes.md in
// the comments below) rather than raw glyphs, which keeps parsing and rendering
// independent of the font.
// ---------------------------------------------------------------------------

enum class NodeKind {
    Row,        // children laid out left to right
    Atom,       // leaf; `code` identifies it
    Frac,       // args: numerator, denominator
    MixedFrac,  // args: integer part, numerator, denominator
    Power,      // args: exponent -- postfix, binds to what precedes it
    Sqrt,       // args: radicand
    Root,       // args: index, radicand
    LogBase,    // args: base, argument
    Abs,        // args: argument
    Sum,        // args: body, from, to      (Sigma)
    Product,    // args: body, from, to      (Pi)
    Integral,   // args: body, lower, upper
    Derivative, // args: body, point
    Recurring   // args: digits under the vinculum
};

class Node;
using NodeP = std::unique_ptr<Node>;

class Node {
public:
    explicit Node(NodeKind kind, QString code = QString());

    static NodeP makeRow();
    static NodeP makeAtom(const QString &code);
    static NodeP makeStructure(NodeKind kind, int argCount);

    NodeKind kind() const { return m_kind; }
    const QString &code() const { return m_code; }
    void setCode(const QString &c) { m_code = c; }

    // Row children (Row nodes only).
    QVector<Node *> children() const;
    int childCount() const { return static_cast<int>(m_children.size()); }
    Node *childAt(int i) const
    {
        return (i >= 0 && i < childCount()) ? m_children[i].get() : nullptr;
    }
    void insertChild(int index, NodeP child);
    NodeP takeChild(int index);
    void clearChildren() { m_children.clear(); }

    // Structural arguments (each one is a Row).
    int argCount() const { return static_cast<int>(m_args.size()); }
    Node *arg(int i) const
    {
        return (i >= 0 && i < argCount()) ? m_args[i].get() : nullptr;
    }

    Node *parent() const { return m_parent; }
    int indexInParent() const;

    bool isRow() const { return m_kind == NodeKind::Row; }
    bool isAtom() const { return m_kind == NodeKind::Atom; }
    bool isStructure() const { return !isRow() && !isAtom(); }

    NodeP clone() const;

    // Flat linear text, mostly for history entries and debugging.
    QString toLinear() const;

    // True when this node can be the operand a postfix operator attaches to.
    bool isOperandEnd() const;

private:
    NodeKind m_kind;
    QString m_code;
    std::vector<NodeP> m_children; // Row only
    std::vector<NodeP> m_args;     // structures only
    Node *m_parent = nullptr;

    friend class Cursor;
};

// A cursor is "inside row `row`, with `index` children to its left".
struct Cursor {
    Node *row = nullptr;
    int index = 0;

    bool isValid() const { return row != nullptr; }
};

// ---------------------------------------------------------------------------
// Atom codes
//
//   digits        "0".."9"  "."  "E" (the x10^x key)
//   arithmetic    "+" "-" "*" "/" "(" ")" "," "neg"
//   postfix       "!" "sqr" "cube" "inv" "deg" "rad" "grad" "pct" "T"(transpose)
//   constants     "pi" "e" "i" "Ran#"
//   variables     "A" "B" "C" "D" "E" "F" "x" "y" "z" "M" "Ans" "PreAns"
//                 "MatA".."MatD" "MatAns" "VctA".."VctD" "VctAns"
//   infix words   "nPr" "nCr" "angle" "and" "or" "xor" "xnor" "->"
//   functions     anything ending in "(" e.g. "sin(" "log(" "RanInt("
// ---------------------------------------------------------------------------

bool atomIsDigit(const QString &code);
bool atomIsFunction(const QString &code);   // opens a parenthesis
bool atomIsPostfix(const QString &code);
bool atomIsInfix(const QString &code);
bool atomIsValue(const QString &code);      // constant or variable

// Glyph shown on the LCD for an atom code.
QString atomGlyph(const QString &code);

} // namespace fx
