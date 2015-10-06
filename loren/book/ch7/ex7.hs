unfold p h t x | p x = []
               | otherwise = h x: unfold p h t (t x)

chop8 :: [Int] -> [[Int]]
chop8  = unfold null (take 8) (drop 8) 


map1 :: (a -> b) -> [a] -> [b]
map1 f = unfold null (f.head) (tail)

iterate1 :: (a ->a) -> a -> [a]
iterate1 f = unfold (const False) id f

