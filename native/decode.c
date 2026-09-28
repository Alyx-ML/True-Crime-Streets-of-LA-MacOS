/* Narrow bridge to the bundled udis86 decoder. No guest instructions execute. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "udis86.h"

struct operand {
    uint32_t kind, value, bits, base, index;
};

struct instruction {
    uint32_t length, flow, target, segmented;
    struct operand operands[3];
    char text[128];
};

int decode(const uint8_t *bytes, size_t size, uint32_t address,
           struct instruction *out)
{
    ud_t u;
    memset(out, 0, sizeof(*out));
    ud_init(&u);
    ud_set_mode(&u, 32);
    ud_set_pc(&u, address);
    ud_set_input_buffer(&u, bytes, size);
    ud_set_syntax(&u, UD_SYN_INTEL);
    out->length = ud_disassemble(&u);
    if (!out->length || u.mnemonic == UD_Iinvalid) return 0;
    snprintf(out->text, sizeof(out->text), "%s", ud_insn_asm(&u));
    out->segmented = u.pfx_seg == UD_R_FS || u.pfx_seg == UD_R_GS;
    /* 0: ordinary, 1: call, 2: jump, 3: conditional, 4: terminal. */
    if (u.mnemonic == UD_Icall) out->flow = 1;
    else if (u.mnemonic == UD_Ijmp) out->flow = 2;
    else if ((u.mnemonic >= UD_Ijo && u.mnemonic <= UD_Ijrcxz) ||
             u.mnemonic == UD_Iloop || u.mnemonic == UD_Iloope ||
             u.mnemonic == UD_Iloopne) out->flow = 3;
    else if (u.mnemonic == UD_Iret || u.mnemonic == UD_Iretf ||
             u.mnemonic == UD_Iint3 || u.mnemonic == UD_Ihlt ||
             u.mnemonic == UD_Iud2) out->flow = 4;
    for (unsigned i = 0; i < 3; ++i) {
        const ud_operand_t *op = &u.operand[i];
        struct operand *dst = &out->operands[i];
        dst->kind = op->type == UD_OP_MEM ? 1 : op->type == UD_OP_IMM ? 2 : 0;
        dst->value = op->lval.udword;
        dst->bits = op->type == UD_OP_MEM ? op->offset : op->size;
        dst->base = op->base;
        dst->index = op->index;
        if (op->type == UD_OP_JIMM) {
            int32_t displacement = op->size == 8 ? op->lval.sbyte :
                                   op->size == 16 ? op->lval.sword : op->lval.sdword;
            out->target = address + out->length + displacement;
        }
    }
    return 1;
}
