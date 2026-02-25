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
export OMP_NUM_THREADS=$NP
export OMP_PROC_BIND=true
export OMP_PLACES=cores

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

    local cmd="./${bin}"
    [[ "$bin" == *"mpi"* ]] && cmd="$(which mpirun) -np ${NP} ./${bin}"

    echo "=== Analyzing ${bin} ==="
        
    cd "${BUILD_DIR}"
        
    # Normal Report (-R1)
    maqao oneview -R1 -xp="${OUTPUT_DIR}/ov_r1_${bin}" --replace -- ${cmd}
        
    # Stability Report (-S1)
    maqao oneview -S1 -xp="${OUTPUT_DIR}/ov_s1_${bin}" --replace -- ${cmd}
        
    # Scalability Report (-R1 -WS)
    maqao oneview -R1 -WS -xp="${OUTPUT_DIR}/ov_ws_${bin}" --replace -- ${cmd}

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
        
    echo "Duel: $binA vs $binB"
        
    maqao oneview --compare-reports \
        --inputs="${OUTPUT_DIR}/ov_r1_${binA},${OUTPUT_DIR}/ov_r1_${binB}" \
        -xp="${OUTPUT_DIR}/cmp_${binA}_vs_${binB}" --replace
done

echo "Done. Reports in $OUTPUT_DIR"