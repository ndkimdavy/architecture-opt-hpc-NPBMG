#!/bin/bash

# Ensure cpu is in performance mode
sudo cpupower frequency-set -g performance
# Ensure maqao kernel.perf_event_paranoid is enabled
sudo sysctl -w kernel.perf_event_paranoid=1

# ==============================================================
# SETUP 
# ==============================================================
BUILD_DIR="$(pwd)/build"
OUTPUT_DIR="${BUILD_DIR}/maqao_reports"
NP=8

# OpenMP environment variables
# - OMP_NUM_THREADS: number of threads used by OpenMP regions
# - OMP_PLACES: define hardware placement (here one thread per core)
# - OMP_PROC_BIND: bind threads close to their parent core to reduce migration
# - OMP_DYNAMIC: disable runtime adjustment of the number of threads
# - OMP_SCHEDULE: static scheduling to reduce scheduling overhead
# - GOMP_CPU_AFFINITY: GCC/libgomp specific CPU pinning to stabilize thread affinity
# - KMP_AFFINITY: LLVM/Intel OpenMP runtime thread affinity policy
# - KMP_BLOCKTIME: reduce idle spin time of worker threads (improves CPU utilization)

OMP_NUM_THREADS=$NP
OMP_PLACES=cores
OMP_PROC_BIND=close
OMP_DYNAMIC=FALSE
OMP_SCHEDULE=static
# GCC / libgomp runtime
GOMP_CPU_AFFINITY="0-$((NP-1))"
# LLVM / AOCC / Intel OpenMP runtime
KMP_AFFINITY=granularity=fine,compact,1,0
KMP_BLOCKTIME=0

BINARIES=(
    "mg_mpi_f90_aocc"
    "mg_mpi_f90_gfortran"
    "mg_mpi_f90_intel"
    "mg_omp_cpp_aocc"
    "mg_omp_cpp_clang++"
    "mg_omp_cpp_g++"
    "mg_omp_cpp_intel"
    "mg_omp_f90_aocc"
    "mg_omp_f90_gfortran"
    "mg_omp_f90_intel"
)

COMPARE_BINARIES=(
    # Compiler Duels
    # 1. MPI(f90_aoc/intel) vs MPI(f90_gfortran)
    # 2. OMP(f90_aoc/intel) vs OMP(f90_gfortran)
    # 3. OMP(cpp_aoc/intel) vs OMP(cpp_clang++)
    # 4. OMP(cpp_aoc/intel) vs OMP(cpp_g++)
    "mg_mpi_f90_aocc" "mg_mpi_f90_gfortran"
    "mg_mpi_f90_intel" "mg_mpi_f90_gfortran"
    "mg_omp_f90_aocc" "mg_omp_f90_gfortran"
    "mg_omp_f90_intel" "mg_omp_f90_gfortran"
    "mg_omp_cpp_aocc" "mg_omp_cpp_clang++"
    "mg_omp_cpp_intel" "mg_omp_cpp_clang++"
    "mg_omp_cpp_aocc" "mg_omp_cpp_g++" 

    # Language & Paradigm Duels
    # 1. OMP(f90_aoc/intel) vs OMP(cpp_aoc/intel)
    # 2. MPI(f90_aoc/intel) vs OMP(f90_aoc/intel)
    # 3. MPI(f90_gfortran) vs OMP(cpp_g++) (NASA official vs NPB-CPP)
    "mg_omp_f90_aocc" "mg_omp_cpp_aocc"
    "mg_omp_f90_intel" "mg_omp_cpp_intel"
    "mg_mpi_f90_aocc" "mg_omp_f90_aocc"
    "mg_mpi_f90_intel" "mg_omp_f90_intel"
    "mg_mpi_f90_gfortran" "mg_omp_cpp_g++"
)

# ==============================================================
# ANALYSE FUNCTION
# ==============================================================
analyze() {
    local bin=$1
    local bin_path="${BUILD_DIR}/${bin}"
    
    # Ensure binary exists skip if not found
    if [[ ! -f "$bin_path" ]]; then
        echo "Error: $bin not found in $BUILD_DIR."
        return
    fi

    local mpi_cmd=""
    local prefix_cmd=""
    if [[ "$bin" == *"mpi"* ]]; then
        mpi_cmd="$(which mpirun) -np ${NP} \
            --bind-to core \
            --map-by core \
            --report-bindings" 
    else
        # Force execution on cores 0..NP-1 to stabilize CPU affinity
        prefix_cmd="$(which taskset) -c 0-$(($NP-1))"
    fi

    echo "=== Analyzing ${bin} ==="

    cd "${BUILD_DIR}"

    # Normal Report (-R1)
    if [[ "$bin" == *"mpi"* ]]; then
    maqao oneview -R1 \
        --number-processes=$NP \
        --mpi-command="$mpi_cmd" \
        -xp="${OUTPUT_DIR}/ov_r1_${bin}" --replace -- ./${bin}
    else
    $prefix_cmd maqao oneview -R1 \
        --envv_OMP_NUM_THREADS=$OMP_NUM_THREADS \
        --envv_OMP_PROC_BIND=$OMP_PROC_BIND \
        --envv_OMP_PLACES=$OMP_PLACES \
        --envv_OMP_DYNAMIC=$OMP_DYNAMIC \
        --envv_OMP_SCHEDULE=$OMP_SCHEDULE \
        --envv_GOMP_CPU_AFFINITY="$GOMP_CPU_AFFINITY" \
        --envv_KMP_AFFINITY="$KMP_AFFINITY" \
        --envv_KMP_BLOCKTIME=$KMP_BLOCKTIME \
        -xp="${OUTPUT_DIR}/ov_r1_${bin}" --replace -- ./${bin}
    fi

    # Stability Report (-S1)
    if [[ "$bin" == *"mpi"* ]]; then
    maqao oneview -S1 --repetitions=10 \
        --number-processes=$NP \
        --mpi-command="$mpi_cmd" \
        -xp="${OUTPUT_DIR}/ov_s1_${bin}" --replace -- ./${bin}
    else
    $prefix_cmd maqao oneview -S1 --repetitions=10 \
        --envv_OMP_NUM_THREADS=$OMP_NUM_THREADS \
        --envv_OMP_PROC_BIND=$OMP_PROC_BIND \
        --envv_OMP_PLACES=$OMP_PLACES \
        --envv_OMP_DYNAMIC=$OMP_DYNAMIC \
        --envv_OMP_SCHEDULE=$OMP_SCHEDULE \
        --envv_GOMP_CPU_AFFINITY="$GOMP_CPU_AFFINITY" \
        --envv_KMP_AFFINITY="$KMP_AFFINITY" \
        --envv_KMP_BLOCKTIME=$KMP_BLOCKTIME \
        -xp="${OUTPUT_DIR}/ov_s1_${bin}" --replace -- ./${bin}
    fi

    # Scalability Report (-R1 -WS)
    if [[ "$bin" == *"mpi"* ]]; then
        # MPI Scalability: 1 -> 2 -> 4 -> 8 processes
        maqao oneview -R1 -WS --number-processes=1 \
            --mpi-command="$(which mpirun) -np <number_processes> --bind-to core --map-by core --report-bindings" \
            --multiruns-params='{{number_processes=2},{number_processes=4},{number_processes=8}}' \
            -xp="${OUTPUT_DIR}/ov_ws_${bin}" --replace -- ./${bin}
    else
        # OpenMP Scalability: 1 -> 2 -> 4 -> 8 threads
        $prefix_cmd \
        maqao oneview -R1 -WS \
        --envv_OMP_PROC_BIND=$OMP_PROC_BIND \
        --envv_OMP_PLACES=$OMP_PLACES \
        --envv_OMP_DYNAMIC=$OMP_DYNAMIC \
        --envv_OMP_SCHEDULE=$OMP_SCHEDULE \
        --envv_GOMP_CPU_AFFINITY="$GOMP_CPU_AFFINITY" \
        --envv_KMP_AFFINITY="$KMP_AFFINITY" \
        --envv_KMP_BLOCKTIME=$KMP_BLOCKTIME \
        --envv_OMP_NUM_THREADS=1 \
        --multiruns-params='{{envv_OMP_NUM_THREADS="2"},{envv_OMP_NUM_THREADS="4"},{envv_OMP_NUM_THREADS="8"}}' \
        -xp="${OUTPUT_DIR}/ov_ws_${bin}" --replace -- ./${bin}
    fi

    cd ..
}

# ==============================================================
# MAIN
# ==============================================================
mkdir -p "$OUTPUT_DIR"

# Individual profiling loop
for bin in "${BINARIES[@]}"; do
    analyze "$bin"
done

# Comparison loop
echo "=== Comparison Reports ==="
for ((i=0; i<${#COMPARE_BINARIES[@]}; i+=2)); do
    binA=${COMPARE_BINARIES[i]}
    binB=${COMPARE_BINARIES[i+1]}

    reportA="${OUTPUT_DIR}/ov_r1_${binA}"
    reportB="${OUTPUT_DIR}/ov_r1_${binB}"

    echo "Duel: $binA vs $binB"

    # Ensure both reports exist before comparing
    if [[ -d "$reportA" && -d "$reportB" ]]; then
        maqao oneview --compare-reports \
            --inputs="${reportA},${reportB}" \
            -xp="${OUTPUT_DIR}/cmp_${binA}_vs_${binB}" --replace
    else
        echo "Skip Duel: One or both reports missing."
        [[ ! -d "$reportA" ]] && echo "  -> Missing: $binA"
        [[ ! -d "$reportB" ]] && echo "  -> Missing: $binB"
        continue
    fi
done

echo "Done. Reports in $OUTPUT_DIR"