# -*- coding: utf-8 -*-
"""
Created on Wed Apr 30 01:33:38 2025

@author: mathi
"""

import numpy as np

from sigima.io.base import FormatInfo
from sigima.io.image.base import SingleImageFormatBase
from pyhdf.SD import SD, SDC

# ==============================================================================
# HDF4 OMEGA file format
# ==============================================================================


class HDF4OImageFormat(SingleImageFormatBase):
    """Object representing HDF4 OMEGA image file type"""

    FORMAT_INFO = FormatInfo(
        name="HDF4 OMEGA",
        extensions="*.hdf",
        readable=True,
        writeable=False,
        requires=["pyhdf"]
    )

    @staticmethod
    def read_data(filename: str) -> np.ndarray:
        """Read data and return it

        Args:
            filename (str): path to hdf file

        Returns:
            np.ndarray: image data
        """
        hdf = SD(filename, SDC.READ)
        if 'Streak_array' in hdf.datasets().keys():
            data = hdf.select('Streak_array')
            img_fore = data[0]
            img_back = data[1]
        elif 'cid_foreground' in hdf.datasets().keys():
            img_fore = hdf.select('cid_foreground').get()
            img_back = hdf.select('cid_background').get()
        else:
            raise NotImplementedError
        img = np.where(img_fore>img_back,img_fore-img_back,0)
        return img