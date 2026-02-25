#!/bin/bash

set -e
set -o pipefail

# ==============================================================
# SETUP
# ==============================================================
CLASS="C"
CLEAN_ENABLED=1

# For AOCC need Spack to be installed
# -fPIC is mandatory for AOCC/LLVM to handle relocations in Class C
FLAGS="-O3 -march=native -fPIC"
COMPILERS=("gfortran" "g++" "clang++" "aocc")

WORK_DIR=$(pwd)
BUILD_DIR="${WORK_DIR}/build"
OFFICIAL_MPI_DIR=("${WORK_DIR}/NPBx/OFFICIAL-NASA/NPB3.4.4/NPB3.4-MPI/MG" "f90")
OFFICIAL_OMP_DIR=("${WORK_DIR}/NPBx/OFFICIAL-NASA/NPB3.4.4/NPB3.4-OMP/MG" "f90")
NOOFFICIAL_OMP_DIR=("${WORK_DIR}/NPBx/NPB-CPP/NPB-OMP/MG" "cpp")

mkdir -p "$BUILD_DIR"

# ==============================================================
# BUILD FUNCTION
# ==============================================================
build() {
    local args=("$@")
    local path="${args[0]}"
    local ext="${args[1]}"
    local compiler="${args[2]}"

    if [[ "$compiler" == "aocc" ]]; then
        echo "Loading AOCC..."
        spack load aocc || { echo "AOCC error"; exit 1; }
        compiler="clang++"
    fi

    echo "Compiling: $path with $compiler"
    cd "$path"

    local config_path="${path}/../config"
    local sys_path="${path}/../sys"
    local make_def="${config_path}/make.def"

    # Restore make.def from template or backup
    if [[ "$path" == *"OFFICIAL-NASA"* ]]; then
        cp "${config_path}/make.def.template" "$make_def"
    fi

    if [[ "$path" == *"NPB-CPP"* ]]; then
        [[ ! -f "$make_def.bak" ]] && cp "$make_def" "$make_def.bak"
        cp "$make_def.bak" "$make_def"
    fi

    if [[ ! -f "${sys_path}/setparams" ]]; then
        cd "$sys_path" && make setparams && cd "$path"
    fi

    # Clean MG and shared common objects if enabled
    if [[ "$CLEAN_ENABLED" == "1" ]]; then
        make clean
        rm -f ../common/*.o
    fi

    # Injection for Fortran (MPI or OMP)
    if [[ "$ext" == "f90" ]]; then
        local fc="$compiler"
        [[ "$path" == *"MPI"* ]] && fc="mpif90"
        
        sed -i "s|^FC[[:space:]]*=.*|FC = $fc|" "$make_def"
        sed -i "s|^F77[[:space:]]*=.*|F77 = $fc|" "$make_def"
        sed -i "s|^FLINK[[:space:]]*=.*|FLINK = $fc|" "$make_def"
        
        local flags_="$FLAGS"
        [[ "$path" == *"OMP"* ]] && flags_="$FLAGS -fopenmp"
        
        sed -i "s|^FFLAGS[[:space:]]*=.*|FFLAGS = $flags_|" "$make_def"
        sed -i "s|^FLINKFLAGS[[:space:]]*=.*|FLINKFLAGS = $flags_|" "$make_def"
        sed -i "s|^WTIME[[:space:]]*=.*|WTIME = wtime.c|" "$make_def"
    else
        # Injection for C++ OMP
        sed -i "s|^CC[[:space:]]*=.*|CC = $compiler|" "$make_def"
        sed -i "s|^CLINK[[:space:]]*=.*|CLINK = \$(CC)|" "$make_def"
        sed -i "s|^CFLAGS[[:space:]]*=.*|CFLAGS = $FLAGS -fopenmp|" "$make_def"
        sed -i "s|^CLINKFLAGS[[:space:]]*=.*|CLINKFLAGS = $FLAGS -fopenmp|" "$make_def"
        sed -i "s|^WTIME[[:space:]]*=.*|WTIME = wtime.cpp|" "$make_def"
    fi

    sed -i "s|^BINDIR[[:space:]]*=.*|BINDIR = ../bin|" "$make_def"

    # Use -r to disable implicit rules (prevents 'default' linker error)
    make -r mg CLASS="$CLASS"

    local type="omp"
    [[ "$path" == *"MPI"* ]] && type="mpi"
    local out_bin="mg_${type}_${ext}_${args[2]}"
    
    # Collect binary from bin/ to build/
    local success=0
    for file in "../bin/mg.$CLASS.x" "../bin/mg.$CLASS"; do
        if [[ -f "$file" ]]; then
            mv "$file" "$BUILD_DIR/$out_bin"
            success=1
            break
        fi
    done

    if [[ "$success" -eq 0 ]]; then
        echo "Error: $out_bin not found"
        exit 1
    fi

    [[ "${args[2]}" == "aocc" ]] && spack unload aocc || true
    cd "$WORK_DIR"
}

# ==============================================================
# MAIN
# ==============================================================
for compiler in "${COMPILERS[@]}"; do
    if [[ "$compiler" == "gfortran" ]]; then
        build "${OFFICIAL_MPI_DIR[@]}" "$compiler"
        build "${OFFICIAL_OMP_DIR[@]}" "$compiler"
    else
        build "${NOOFFICIAL_OMP_DIR[@]}" "$compiler"
    fi
done

# ==============================================================
# GENERATE INPUT TEMPLATE
# ==============================================================
INPUT_FILE="${BUILD_DIR}/mg.input"
if [ ! -f "$INPUT_FILE" ]; then
    echo "Generating mg.input template in ${BUILD_DIR}..."
    cat <<EOF > "$INPUT_FILE"
10              # lt: Class index (Max levels, use 10 for Class C)
512 512 512     # nx ny nz: Grid dimensions (Must match compiled Class)
20              # nit: Total number of iterations to run
0 0 0 0 0 0 0 0 # debug_vec: 8 flags to control debug output
EOF
fi

echo "Done. Binaries in $BUILD_DIR"