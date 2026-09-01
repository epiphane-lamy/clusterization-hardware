/*
 * Reference model generator for the entropy-based 2D clustering pipeline.
 *
 * This code is based on C code by **Elias de Almeida Ramos**, the original
 * code can be found in frontend/src_c/clusterization_float.c.
 *
 * Produces every artifact the hardware flow needs to run and verify against
 * a given 2D point benchmark, and keeps the RTL testbench in sync with it:
 *   - LUT contents for the exp() and inverse LUTs (see ADR-0004)
 *   - the per-iteration K_step ROM (k_step_rom.hex)
 *   - the benchmark itself, re-centered/scaled and quantized to fixed-point
 *     (cluster_fixed_full_benchmark.txt) -- this is the exact input the RTL
 *     testbench loads (see clusterization_tb.sv)
 *   - the bit-exact fixed-point reference computation itself: Gaussian
 *     kernel, row normalization, Gini entropy, Ricci gradient, and the
 *     entropy-modulated position update, run for NB_ITER iterations and a
 *     final clustering pass -- exactly the computation the RTL is checked
 *     against (see docs/ARCHITECTURE.md, sections 8 and 10)
 *   - resultats_c.txt: the software-side result file used for the
 *     side-by-side software/RTL comparison described in the README
 *
 * It also patches clusterization_tb.sv's NB_POINTS parameter and
 * plot_benchmark.sh's BENCHMARK_FILE variable to match whatever benchmark
 * is pointed to below, so that changing BENCHMARK_FILE and re-running this
 * program is the only step needed before re-running the RTL simulation and
 * plotting scripts on a new benchmark (see the README's
 * "Reproducing the clustering pipeline" section).
 *
 * A parallel floating-point computation is kept alongside the fixed-point
 * one throughout -- not for error-checking anymore (that validation, and
 * the reasoning behind every fixed-point format choice below, is already
 * covered in the ADRs referenced inline), but because it's what the
 * fixed-point computation is a quantized approximation of, and keeping it
 * visible side by side is useful documentation in its own right.
 */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <stdint.h>
#include <string.h>

#define INITIAL_CAPACITY 2000 // Initial capacity of the dynamically-grown point arrays
#define LUT_SIZE 10241        // exp LUT size: 10240 entries for arg in [-10, 0) in Q6.10, +1 for arg = 0 (see ADR-0004)

// RTL testbench whose NB_POINTS parameter gets patched below
#define TB_FILE "../tb/clusterization_tb.sv"
// Plotting script whose BENCHMARK_FILE variable gets patched below
#define SCRIPT_FILE "../scripts/plot_benchmark.sh"

// ==============================================================
// Patches the BENCHMARK_FILE="..." line to point to the selected
// benchmark, ensuring that the plotting scripts always use the
// benchmark processed by this program and that the corresponding
// fixed-point benchmark file is generated for RTL simulation.
// ==============================================================
// 2D point benchmark to process -- change this and re-run to target a new benchmark
#define BENCHMARK_FILE "../data/cluster.txt"

void update_plot_script(void) {
    /*
    * Updates the plotting script to use the benchmark processed by the
    * reference model.
    *
    * Replaces the BENCHMARK_FILE variable in the plotting script with the
    * benchmark specified by BENCHMARK_FILE, while preserving all other lines.
    * The update is performed through a temporary file to avoid modifying the
    * original script until the new version has been successfully generated.
    */
    FILE *input = fopen(SCRIPT_FILE, "r");
    if (input == NULL) {
        perror("Error opening script");
        return;
    }

    FILE *output = fopen("../scripts/plot_benchmark.tmp", "w");
    if (output == NULL) {
        perror("Error creating temporary file");
        fclose(input);
        return;
    }

    char line[2048];
    while (fgets(line, sizeof(line), input)) {

        // Look for the line that starts with BENCHMARK_FILE=
        if (strncmp(line, "BENCHMARK_FILE=", strlen("BENCHMARK_FILE=")) == 0) {
            // Replace the whole line
            fprintf(output, "BENCHMARK_FILE=\"%s\"\n", BENCHMARK_FILE);
        }
        else {
            // Copy every other line unchanged
            fputs(line, output);
        }
    }
    fclose(input);
    fclose(output);

    // Replace the old script
    if (remove(SCRIPT_FILE) != 0) {
        perror("Error deleting the old script");
        remove("../scripts/plot_benchmark.tmp");
        return;
    }

    if (rename("../scripts/plot_benchmark.tmp", SCRIPT_FILE) != 0) {
        perror("Error renaming the temporary file");
        return;
    }

    printf("BENCHMARK_FILE updated: %s\n\n", BENCHMARK_FILE);
}

void update_testbench(int n_total, int tol_fixed) {
    /*
    * Updates the testbench to use the correct number of points processed
    * by the reference model and the corresponding TOL constant.
    *
    * Replaces the NB_POINTS and TOL parameters in clusterization_tb.sv
    * with the number of points and TOL value of the current benchmark,
    * while preserving all other lines. The update is performed through
    * a temporary file to avoid modifying the original testbench until
    * the new version has been successfully generated.
    */
    FILE *in = fopen(TB_FILE, "r");
    if (!in) {
        perror("Could not open the testbench");
        return;
    }

    FILE *out = fopen("../tb/clusterization_tb.tmp", "w");
    if (!out) {
        perror("Could not create the temporary file");
        fclose(in);
        return;
    }

    char line[1024];

    while (fgets(line, sizeof(line), in)) {
        if (strstr(line, "parameter int NB_POINTS")) {
            fprintf(out,
                    "    parameter int NB_POINTS    = %d,        // Number of points\n",
                    n_total);
        }
        else if (strstr(line, "parameter int TOL")) {
            fprintf(out,
                    "    parameter int TOL          = %d    // Squared-distance tolerance for cluster_assign, precomputed in software\n",
                    tol_fixed);
        }
        else {
            fputs(line, out);
        }
    }

    fclose(in);
    fclose(out);

    if (remove(TB_FILE) != 0) {
        perror("Could not delete the old testbench");
        return;
    }

    if (rename("../tb/clusterization_tb.tmp", TB_FILE) != 0) {
        perror("Could not rename the temporary file");
        return;
    }

    printf("Testbench updated:\n");
    printf("NB_POINTS = %d\n", n_total);
    printf("TOL       = %d\n", tol_fixed);

}

int main() {
    update_plot_script();


    // -------------------------------------------------------------------
    // exp LUT: exp_lut[i] = exp(-10 + i/1024), Q0.16, for i in [0, 10240]
    // (argument in Q6.10 -- see ADR-0004 for why this range and format).
    // -------------------------------------------------------------------
    uint16_t exp_lut[LUT_SIZE];
    FILE *f_exp_LUT = fopen("../data/exp_lut.hex","w");
    
    for(int i=0;i<LUT_SIZE;i++) {
        // Reconstruct the real-valued argument
        float arg = -10.0f + ((float)i / 1024.0f); // divide by 1024: Q6.10 format

        // Real exponential
        float y = expf(arg);

        float q = y * 65536.0f;

        if (q > 65535.0f)
            q = 65535.0f;

        exp_lut[i] = (uint16_t)q;
        fprintf(f_exp_LUT, "%04X\n", q);
    }
    fclose(f_exp_LUT);


    // -------------------------------------------------------------------
    // Inverse LUT: inv[i] = 1/(1 + i/1024), Q0.16, addressed by mantissa
    // (see ADR-0004 -- this is what lets a 1024-entry table cover the wide
    // dynamic range of the row sum being inverted).
    // -------------------------------------------------------------------
    uint32_t inv[1024];
    uint32_t result_inv;
    FILE *f_inv_LUT = fopen("../data/inv_lut.hex","w");

    for(int i=0;i<1024;i++) {
        double m = 1.0 + ((double)i / 1024.0);

        result_inv = (uint32_t)((1.0 / m) * 65536.0);
        if (result_inv > 65535)
            result_inv = 65535;

        fprintf(f_inv_LUT, "%04X\n", result_inv);

        inv[i] = result_inv;
    }
    fclose(f_inv_LUT);



    // --- 1. DATA INGESTION (X, Y) ---
    printf("--- L.E.G.I.A.O. V3 [2D MODE]: PROCESSING PLANAR MAP ---\n");

    FILE *file = fopen(BENCHMARK_FILE, "r");
    if (file == NULL) {
        printf("Error while opening the file cluster.txt\n");
        return 1;
    }

    int capacity = INITIAL_CAPACITY;
    double *X = (double *)malloc(capacity * sizeof(double));
    double *Y = (double *)malloc(capacity * sizeof(double));
    int n_total = 0;

    double val1, val2;
    while (fscanf(file, "%lf %lf%*[^\n]", &val1, &val2) == 2) {
        if (n_total >= capacity) {
            capacity *= 2;
            X = (double *)realloc(X, capacity * sizeof(double));
            Y = (double *)realloc(Y, capacity * sizeof(double));
        }
        X[n_total] = val1;
        Y[n_total] = val2;
        n_total++;
    }
    fclose(file);

    if (n_total == 0) {
        printf("Error: No valid data loaded.\n");
        free(X); free(Y);
        return 1;
    }
    printf("Success: %d points loaded for 2D processing.\n", n_total);

    // ================================================================
    // Normalization: re-center the point cloud around the origin and scale
    // it into a fixed range, independent of (and prior to) the Q8.8
    // quantization performed further down. norm_scale/center_x/center_y are
    // written into the benchmark file's header and reused by the RTL
    // testbench to reconstruct real-world coordinates for the results file.
    // ================================================================
    float x_min = X[0];
    float x_max = X[0];
    float y_min = Y[0];
    float y_max = Y[0];

    for (int i = 1; i < n_total; i++) {
        if (X[i] < x_min) x_min = X[i];
        if (X[i] > x_max) x_max = X[i];

        if (Y[i] < y_min) y_min = Y[i];
        if (Y[i] > y_max) y_max = Y[i];
    }

    float center_x = (x_min + x_max) * 0.5f;
    float center_y = (y_min + y_max) * 0.5f;

    float rangex = x_max - x_min;
    float rangey = y_max - y_min;

    float range_n = (rangex > rangey) ? rangex : rangey;

    float norm_scale = 2.0f / range_n;

    // Normalize the point coordinates to the range [-1, 1]
    for (int i = 0; i < n_total; i++) {
        X[i] = (X[i] - center_x) * norm_scale;
        Y[i] = (Y[i] - center_y) * norm_scale;
    }    

    // Allocation of dynamic vectors after ingestion
    double  *X_float = (double  *)malloc(n_total * sizeof(double));
    double  *Y_float = (double  *)malloc(n_total * sizeof(double));
    int32_t *X_f     = (int32_t *)malloc(n_total * sizeof(int32_t));
    int32_t *Y_f     = (int32_t *)malloc(n_total * sizeof(int32_t));

    // Entropy
    double  *H       = (double  *)malloc(n_total * sizeof(double));
    int32_t *H_fixed = (int32_t *)malloc(n_total * sizeof(int32_t));

    // Gradient
    double  *grad_x_float = (double  *)malloc(n_total * sizeof(double));
    double  *grad_y_float = (double  *)malloc(n_total * sizeof(double));
    int32_t *grad_x       = (int32_t *)malloc(n_total * sizeof(int32_t));
    int32_t *grad_y       = (int32_t *)malloc(n_total * sizeof(int32_t));

    // force 
    double  *force_float = (double  *)malloc(n_total * sizeof(double));
    int32_t *force       = (int32_t *)malloc(n_total * sizeof(int32_t));
    
    float xmin = X[0];
    float xmax = X[0];
    float ymin = Y[0];
    float ymax = Y[0];

    for (int i = 1; i < n_total; i++) {
        if (X[i] < xmin) xmin = X[i];
        if (X[i] > xmax) xmax = X[i];

        if (Y[i] < ymin) ymin = Y[i];
        if (Y[i] > ymax) ymax = Y[i];
    }
    float range_x = xmax - xmin;
    float range_y = ymax - ymin;

    // Use the larger of the two ranges to preserve the X/Y aspect ratio
    float range = (range_x > range_y) ? range_x : range_y;

    float scale_points = 255.0f / range;

    printf("range = %f\n", range);
    printf("scale = %f\n", 255.0f/range);
    printf("scale² = %f\n", (255.0f/range)*(255.0f/range));

    uint8_t *X_q = malloc(n_total * sizeof(uint8_t));
    uint8_t *Y_q = malloc(n_total * sizeof(uint8_t));

    // Convert the normalized coordinates to an 8-bit unsigned fixed-point representation [0, 255].
    for (int i = 0; i < n_total; i++) {
        X_q[i] = (uint8_t)roundf((X[i] - xmin) * scale_points);
        Y_q[i] = (uint8_t)roundf((Y[i] - ymin) * scale_points);
    }

    // Convert the 8-bit coordinates to Q8.8 fixed-point format.
    for (int i = 0; i < n_total; i++) {
        X_float[i] = X[i];
        Y_float[i] = Y[i];
        X_f[i]     = ((int16_t)X_q[i]) << 8;
        Y_f[i]     = ((int16_t)Y_q[i]) << 8;
    }

    // Fixed-point benchmark file: this is what the RTL testbench loads
    // directly (see clusterization_tb.sv). Header carries every parameter
    // needed to reconstruct real-world coordinates from the fixed-point
    // values in the results file.
    FILE *f_fixed = fopen("../data/cluster_fixed_full_benchmark.txt", "w");
    if (f_fixed == NULL) {
        printf("Error opening cluster_fixed_full_benchmark.txt\n");
        return 1;
    }

    fprintf(f_fixed, "%f %f %f %f %f %f\n", scale_points, xmin, ymin, norm_scale, center_x, center_y);
    for (int i = 0; i < n_total; i++) {
        fprintf(f_fixed, "%d %d\n", X_f[i], Y_f[i]);
    }

    fclose(f_fixed);


    // Dynamic two-dimensional matrix P (fixed-point and floating-point,
    // kept side by side -- see the header comment).
    double   **P_float = (double **)malloc(n_total * sizeof(double *));
    uint16_t **P       = (uint16_t **)malloc(n_total * sizeof(uint16_t *));
    for (int i = 0; i < n_total; i++) {
        P_float[i] = (double *)malloc(n_total * sizeof(double));
        P[i] = (uint16_t *)malloc(n_total * sizeof(uint16_t));
    }

    // --- 2. L.E.G.I.A.O. 2D ENGINE (MATRIX PLANAR RICCI FLOW) ---
    double   T_float = 1.003;
    uint32_t T_q8_8  = (uint32_t)(scale_points * T_float * 256.0);
    double   T_real  = T_q8_8 / 256.0;
    
    double alpha_float = 1.028;
    uint32_t alpha = (uint32_t)(1.028 * 65536);

    double surgical_threshold = 7.7;           // Shannon-entropy surgery threshold (float path)
    uint32_t surgical_threshold_fixed = 65200; // Equivalent Gini-entropy threshold (fixed path, see ADR-0005)

    int max_iter = 50;

    clock_t start_time = clock();
    printf("\n--- RUNNING 2D COLLAPSE ---\n");

    FILE *f_hex = fopen("../data/k_step_rom.hex", "w");

    for (int step = 0; step < max_iter; step++) {
        double K_float = 1.0 / (2.0 * T_real * T_real);

        uint16_t K_fixed = (uint16_t)(K_float * 65536.0);
        fprintf(f_hex, "%04X\n", (uint16_t)-K_fixed);

        int16_t K_fixed_signed = -(int16_t)K_fixed;
        
        double max_error = 0;
        // Step A: Distance matrix D2 and Gaussian kernel P calculation
        for (int i = 0; i < n_total; i++) {
            double sum_row_P_float = 0.0;
            uint32_t sum_row_P = 0.0;
            
            for (int j = 0; j < n_total; j++) {
                int32_t dx = X_f[i] - X_f[j];
                int32_t dy = Y_f[i] - Y_f[j];
                double dx_float = X_float[i] - X_float[j];
                double dy_float = Y_float[i] - Y_float[j];

                // square distance
                int64_t D2_fixed = (int64_t)dx * dx + (int64_t)dy * dy;
                double D2_float = dx_float * dx_float + dy_float * dy_float;

                int64_t mult = D2_fixed * -(K_fixed);

                int64_t arg_q16_16 = (mult >> 16);
                double arg_float = -D2_float / (2*T_float*T_float);
                
                double arg_fixed = arg_q16_16 / 65536.0;

                if(arg_q16_16 > 0)
                {
                    printf("arg_q16_16 positive : %ld\n", arg_q16_16);
                    exit(1);
                }
                int64_t arg_q6_10;

                arg_q6_10 = arg_q16_16 >> 6;
                if(arg_q6_10 > 0)
                {
                    printf("arg_q6_10 positive : %ld\n", arg_q6_10);
                    exit(1);
                }
                
                // Saturate to 0 below the LUT's lower bound (arg < -10),
                // otherwise look up exp(arg) via the LUT (see ADR-0004)
                if(arg_q6_10 <= -(10 * 1024)){
                    P[i][j] = 0;
                }
                else {
                    int index = arg_q6_10 + 10240;
                    P[i][j] = exp_lut[index];
                }
                P_float[i][j] = exp(arg_float);

                sum_row_P += P[i][j];

                sum_row_P_float += P_float[i][j];
            }

            
            // Row normalization: fixed-point via the mantissa-addressed
            // inverse LUT (see ADR-0004), floating-point via direct division
            // (kept matching MATLAB's P = P ./ (sum(P, 2) + 1e-12)).
            H[i] = 0.0;
            H_fixed[i] = 0.0;
            uint64_t gini_acc = 0;

            for (int j = 0; j < n_total; j++) {

                uint16_t P_before = P[i][j];

                if(sum_row_P == 0)
                    P[i][j] = 0;
                else{
                    int msb = 31 - __builtin_clz(sum_row_P);
                    uint32_t mantissa = sum_row_P << (31 - msb);
                    uint32_t addr = (mantissa >> 22) & 0x3FF;

                    uint64_t mult = (uint64_t)P_before * inv[addr];

                    P[i][j] = mult >> msb;
                }
                
                P_float[i][j] /= (sum_row_P_float + 1e-12);
                
                double P_fixed = P[i][j] / 65536.0;

                double error = fabs(P_float[i][j]-P_fixed);

                if(error > max_error)
                    max_error = error;

                H[i] -= P_float[i][j] * log2(P_float[i][j] + 1e-12); // Shannon entropy (float path)

                uint16_t p = P[i][j];
                gini_acc += ((uint64_t)p*p)>>16;
            }
            H_fixed[i] = 65536 - gini_acc; // Gini entropy (fixed path, see ADR-0005)
        }

        // Step B: Ricci gradients and position updates
        for (int i = 0; i < n_total; i++) {
            double P_dot_X_float = 0.0;
            double P_dot_Y_float = 0.0;
            int64_t P_dot_X = 0;
            int64_t P_dot_Y = 0;
            for (int j = 0; j < n_total; j++) {
                P_dot_X_float += P_float[i][j] * X_float[j];
                P_dot_Y_float += P_float[i][j] * Y_float[j];

                int64_t temp_X = P[i][j] * X_f[j];
                P_dot_X += temp_X;

                int64_t temp_Y = P[i][j] * Y_f[j];
                P_dot_Y += temp_Y;
            }
            P_dot_X = P_dot_X >> 16;
            P_dot_Y = P_dot_Y >> 16;

            grad_x_float[i] = P_dot_X_float - X_float[i];
            grad_y_float[i] = P_dot_Y_float - Y_float[i];
            grad_x[i] = P_dot_X - X_f[i];
            grad_y[i] = P_dot_Y - Y_f[i];

            // Perelman-surgery force modulation based on the entropy threshold
            force_float[i] = 0.35;
            force[i] = (int32_t)(0.35 * 65536);
            if (H[i] > surgical_threshold) {
                force_float[i] = 0.002;
            }
            if (H_fixed[i] > surgical_threshold_fixed) {
                force[i] = (int32_t)(0.002 * 65536);
            }
        }
        
        // Synchronous update of every point (avoids order-dependent
        // distortions within a single iteration)
        for (int i = 0; i < n_total; i++) {
            X_float[i] += force_float[i] * grad_x_float[i];
            Y_float[i] += force_float[i] * grad_y_float[i];

            int64_t mult_act_X = ((int64_t)force[i] * grad_x[i]) >> 16;
            int64_t mult_act_Y = ((int64_t)force[i] * grad_y[i]) >> 16;

            X_f[i] += ((int64_t)force[i] * grad_x[i]) >> 16;
            Y_f[i] += ((int64_t)force[i] * grad_y[i]) >> 16;
        }

        T_q8_8 = (uint32_t)(((uint64_t)T_q8_8 * alpha) >> 16);
        T_real = T_q8_8 / 256.0;
        T_float *= alpha_float;
    }

    fclose(f_hex);
    clock_t end_time = clock();
    double t_calc = (double)(end_time - start_time) / CLOCKS_PER_SEC;

    // --- 3. FINAL GEOMETRIC CLUSTERING ---
    int *cluster_labels = (int *)malloc(n_total * sizeof(int));
    for (int i = 0; i < n_total; i++) cluster_labels[i] = -1;
    int *cluster_labels_fixed = (int *)malloc(n_total * sizeof(int));
    for (int i = 0; i < n_total; i++) cluster_labels_fixed[i] = -1;

    int num_clusters_float = 0;
    int num_clusters_fixed = 0;
    
    // Distance tolerance for merging two points into the same cluster
    double tol = 0.4 * 0.4;

    double scale_coord = (double)scale_points * 256.0;
    uint64_t tol_fixed = (uint64_t)(tol * scale_coord * scale_coord);

    // ================================================================
    // Patch the RTL testbench's NB_POINTS/TOL parameters to match this
    // benchmark's point count (see the header comment for why).
    // ================================================================
    update_testbench(n_total, tol_fixed);

    for (int i = 0; i < n_total; i++) {
        if (cluster_labels[i] != -1) continue;

        cluster_labels[i] = num_clusters_float;

        for (int j = i + 1; j < n_total; j++) {
            if (cluster_labels[j] == -1) {
                double dx_float = X_float[i] - X_float[j];
                double dy_float = Y_float[i] - Y_float[j];

                double dist_float = dx_float * dx_float + dy_float * dy_float;

                if (dist_float <= tol) {
                    cluster_labels[j] = num_clusters_float;
                }
            }
        }
        num_clusters_float++;
    }

    for (int i = 0; i < n_total; i++) {
        if (cluster_labels_fixed[i] != -1) continue;

        cluster_labels_fixed[i] = num_clusters_fixed;

        for (int j = i + 1; j < n_total; j++) {
            if (cluster_labels_fixed[j] == -1) {
                int32_t dx = X_f[i] - X_f[j];
                int32_t dy = Y_f[i] - Y_f[j];

                int64_t dist_fixed = (int64_t)dx * dx + (int64_t)dy * dy;

                if (dist_fixed <= tol_fixed) {
                    cluster_labels_fixed[j] = num_clusters_fixed;
                }
            }
        }
        num_clusters_fixed++;
    }

    FILE *file_in = fopen(BENCHMARK_FILE, "r");
    FILE *file_out_software = fopen("../data/resultats_c.txt", "w");
    FILE *file_out_software_float = fopen("../data/resultats_c_float.txt", "w");
    double val3_old;
    int i = 0;
    // Software-side result file (fixed-point & float path): original coordinates
    // plus the assigned cluster number, for the side-by-side software/RTL
    // comparison described in the README.
    while (fscanf(file_in, "%lf %lf %lf", &val1, &val2, &val3_old) == 3) {
        fprintf(file_out_software, "%.14f %.14f %d\n", val1, val2, cluster_labels_fixed[i]);
        fprintf(file_out_software_float, "%.14f %.14f %d\n", val1, val2, cluster_labels[i]);
        i++;
    }
    fclose(file_in);
    fclose(file_out_software);
    fclose(file_out_software_float);
    
    int *cluster_sizes = (int *)calloc(num_clusters_float, sizeof(int));
    for (int i = 0; i < n_total; i++) {
        cluster_sizes[cluster_labels[i]]++;
    }

    // --- 4. SUMMARY REPORT ---
    printf("\n------------------------------------------------------------------\n");
    printf("L.E.G.I.A.O. 2D: cosmic filaments revealed successfully (%.2fs)\n", t_calc);
    printf("------------------------------------------------------------------\n");
    
    int thresh = 5; // Ignore noise: clusters smaller than 5 scattered points
    int real_clusters_count = 0;
    int noise_points = 0;

    for (int c = 0; c < num_clusters_float; c++) {
        if (cluster_sizes[c] >= thresh) real_clusters_count++;
    }

    printf(">> TOTAL CLUSTERS DETECTED IN THE COSMIC WEB: %d <<\n", real_clusters_count);
    printf("------------------------------------------------------------------\n");
    printf("Final node population metrics:\n");

    int display_id = 1;
    for (int c = 0; c < num_clusters_float; c++) {
        if (cluster_sizes[c] >= thresh) {
            printf("  * Macro-structure #%02d: %d galaxies/points (%.1f%% of the map)\n",
                   display_id++, cluster_sizes[c], ((double)cluster_sizes[c] / n_total) * 100.0);
        } else {
            noise_points += cluster_sizes[c];
        }
    }

    if (noise_points > 0) {
        printf("  * Diffuse filaments/orbital noise: %d scattered points\n", noise_points);
    }
    printf("------------------------------------------------------------------\n");

    // Memory cleanup
    free(X); free(Y); free(X_f); free(X_float); free(Y_float); free(Y_f); free(X_q); free(Y_q);
    free(H); free(H_fixed);
    free(grad_x); free(grad_y); free(grad_x_float); free(grad_y_float);
    free(force_float); free(force);
    free(cluster_labels); free(cluster_labels_fixed); free(cluster_sizes);
    for (int i = 0; i < n_total; i++) {
        free(P[i]);
        free(P_float[i]);
    }
    free(P_float);
    free(P);

    return 0;
}
