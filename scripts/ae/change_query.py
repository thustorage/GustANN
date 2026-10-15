import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import io_utils
import numpy as np

def main():
    if (len(sys.argv) != 4):
        print(f"Usage {sys.argv[0]} <Input Query> <Rep> <Output Query>")
        exit(-1)
    data = io_utils.fvecs_read(sys.argv[1])
    n, m = data.shape
    rep = int(sys.argv[2])
    new_data = np.empty((n, m * rep), dtype = 'float32')

    for i in range(n):
        for j in range(m):
            for k in range(rep):
                new_data[i, j * rep + k] = data[i, j]
    
    io_utils.fvecs_write(sys.argv[3], new_data)

if __name__ == "__main__":
    main()
