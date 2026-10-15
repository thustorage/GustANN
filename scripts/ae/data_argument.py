import numpy as np
from random import randint

def ivecs_read(fname):
    a = np.fromfile(fname, dtype='int32')
    d = a[0]
    return a.reshape(-1, d + 1)[:, 1:].copy()

def bvecs_read(fname):
    a = np.fromfile(fname, dtype='uint8')
    d = a[:4].view('int32')[0]
    return a.reshape(-1, d + 4)[:, 4:].copy()

def fvecs_read(fname):
    return ivecs_read(fname).view('float32')

def ivecs_write(fname, m):
    n, d = m.shape
    m1 = np.empty((n, d + 1), dtype='int32')
    m1[:, 0] = d
    m1[:, 1:] = m
    m1.tofile(fname)

def bvecs_write(fname, m):
    n, d = m.shape
    m1 = np.empty((n, d + 4), dtype='uint8')
    m1[:, :4] = np.array([d], dtype='int32').view('uint8')
    m1[:, 4:] = m
    m1.tofile(fname)

def fvecs_write(fname, m):
    m = m.astype('float32')
    ivecs_write(fname, m.view('int32'))

def write_ibin(filename, vecs):
    """ Write an array of int32 vectors to *.ibin file
    Args:
        :param filename (str): path to *.ibin file
        :param vecs (numpy.ndarray): array of int32 vectors to write
    """
    assert len(vecs.shape) == 2, "Input array must have 2 dimensions"
    with open(filename, "wb") as f:
        nvecs, dim = vecs.shape
        f.write(struct.pack('<i', nvecs))
        f.write(struct.pack('<i', dim))
        vecs.astype('int32').flatten().tofile(f)

def write_fbin(filename, vecs):
    """ Write an array of float32 vectors to *.fbin file
    Args:s
        :param filename (str): path to *.fbin file
        :param vecs (numpy.ndarray): array of float32 vectors to write
    """
    assert len(vecs.shape) == 2, "Input array must have 2 dimensions"
    with open(filename, "wb") as f:
        nvecs, dim = vecs.shape
        f.write(struct.pack('<i', nvecs))
        f.write(struct.pack('<i', dim))
        vecs.astype('float32').flatten().tofile(f)


def main(data, num, seg):
    m, d = data.shape
    print(m, d)
    result = np.zeros((num, d))

    assert(d % seg == 0)
    for i in range(num):
        for j in range(0, d, seg):
            target = randint(0, m - 1)
            result[i, j:j+seg]=data[target,j:j+seg]

    return result
    
if __name__ == '__main__':
    ifile = "/mnt/data/jhd/data/sift/bigann_query.bvecs"
    ofile = "/mnt/data/jhd/data/sift/bigann_query_arg.bvecs"
    data = bvecs_read(ifile)
    result = main(data, 10**6, 8)
    bvecs_write(ofile, result)
    
