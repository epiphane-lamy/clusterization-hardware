#include <stdio.h>
#include <stdint.h>

#define EXP_LUT_SIZE 10241
#define INV_LUT_SIZE 1024

/* ============================================================
 * Génération de exp_LUT_synth.sv
 * ============================================================ */
int generate_exp_lut(void)
{
    FILE *fin  = fopen("../data/exp_lut.hex", "r");
    FILE *fout = fopen("../synth_files/exp_LUT_synth.sv", "w");

    if (fin == NULL) {
        perror("Erreur ouverture exp_lut.hex");
        return 1;
    }

    if (fout == NULL) {
        perror("Erreur creation exp_LUT_synth.sv");
        fclose(fin);
        return 1;
    }

    fprintf(fout,
        "module exp_LUT #(\n"
        "    parameter INDEX_W = 14\n"
        ")(\n"
        "    input  logic                 clk,\n"
        "    input  logic                 rst_n,\n"
        "\n"
        "    input  logic [INDEX_W-1:0]   index,\n"
        "    output logic [15:0]          result_exp\n"
        ");\n"
        "\n"
        "    logic [15:0] exp_value;\n"
        "\n"
        "    always_comb begin\n"
        "        case (index)\n"
    );

    char line[64];

    for (int i = 0; i < EXP_LUT_SIZE; i++) {

        if (fgets(line, sizeof(line), fin) == NULL) {
            fprintf(stderr,
                    "Erreur : exp_lut.hex contient seulement %d valeurs\n",
                    i);
            fclose(fin);
            fclose(fout);
            return 1;
        }

        uint16_t data;

        if (sscanf(line, "%hx", &data) != 1) {
            fprintf(stderr,
                    "Erreur lecture exp LUT adresse %d : %s",
                    i, line);
            fclose(fin);
            fclose(fout);
            return 1;
        }

        fprintf(fout,
                "            14'd%d: exp_value = 16'h%04X;\n",
                i, data);
    }

    fprintf(fout,
        "            default: exp_value = 16'h0000;\n"
        "        endcase\n"
        "    end\n"
        "\n"
        "    always_ff @(posedge clk) begin\n"
        "        result_exp <= exp_value;\n"
        "    end\n"
        "\n"
        "endmodule\n"
    );

    fclose(fin);
    fclose(fout);

    printf("EXP LUT : %d valeurs generees -> exp_LUT_synth.sv\n",
           EXP_LUT_SIZE);

    return 0;
}


/* ============================================================
 * Génération de inv_LUT_synth.sv
 * ============================================================ */
int generate_inv_lut(void)
{
    FILE *fin  = fopen("../data/inv_lut.hex", "r");
    FILE *fout = fopen("../synth_files/inv_LUT_synth.sv", "w");

    if (fin == NULL) {
        perror("Erreur ouverture inv_lut.hex");
        return 1;
    }

    if (fout == NULL) {
        perror("Erreur creation inv_LUT_synth.sv");
        fclose(fin);
        return 1;
    }

    fprintf(fout,
        "module inv_LUT #(\n"
        "    parameter INDEX_W = 10\n"
        ")(\n"
        "    input  logic                 clk,\n"
        "    input  logic                 rst_n,\n"
        "\n"
        "    input  logic [INDEX_W-1:0]   index,\n"
        "    output logic [15:0]          result_inv\n"
        ");\n"
        "\n"
        "    logic [15:0] inv_value;\n"
        "\n"
        "    always_comb begin\n"
        "        case (index)\n"
    );

    char line[64];

    for (int i = 0; i < INV_LUT_SIZE; i++) {

        if (fgets(line, sizeof(line), fin) == NULL) {
            fprintf(stderr,
                    "Erreur : inv_lut.hex contient seulement %d valeurs\n",
                    i);
            fclose(fin);
            fclose(fout);
            return 1;
        }

        uint16_t data;

        if (sscanf(line, "%hx", &data) != 1) {
            fprintf(stderr,
                    "Erreur lecture INV LUT adresse %d : %s",
                    i, line);
            fclose(fin);
            fclose(fout);
            return 1;
        }

        fprintf(fout,
                "            10'd%d: inv_value = 16'h%04X;\n",
                i, data);
    }

    fprintf(fout,
        "            default: inv_value = 16'h0000;\n"
        "        endcase\n"
        "    end\n"
        "\n"
        "    always_ff @(posedge clk) begin\n"
        "        result_inv <= inv_value;\n"
        "    end\n"
        "\n"
        "endmodule\n"
    );

    fclose(fin);
    fclose(fout);

    printf("INV LUT : %d valeurs generees -> inv_LUT_synth.sv\n",
           INV_LUT_SIZE);

    return 0;
}


/* ============================================================
 * MAIN
 * ============================================================ */
int main(void)
{
    int error = 0;

    printf("Generation des LUT...\n\n");

    error |= generate_exp_lut();
    error |= generate_inv_lut();

    if (error) {
        printf("\nERREUR lors de la generation.\n");
        return 1;
    }

    printf("\nGeneration terminee avec succes.\n");

    return 0;
}